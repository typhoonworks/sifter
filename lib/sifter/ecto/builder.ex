defmodule Sifter.Ecto.Builder do
  @moduledoc """
  The Builder transforms parsed `Sifter.AST` nodes into Ecto query expressions.

  This module serves as the bridge between Sifter's abstract syntax tree representation
  and Ecto's query DSL, generating dynamic SQL fragments that can be applied to Ecto queries.
  The Builder handles field validation, type casting, association joins, and full-text search
  strategies while providing comprehensive metadata about the generated query.

  ## Supported Operations

  The Builder supports all comparison and set operations defined in `Sifter.AST`:

  - **Equality**: `:eq` (`:`) - Exact match or wildcard patterns
  - **Inequality**: `:neq` - Not equal comparison
  - **Relational**: `:gt` (`>`), `:gte` (`>=`), `:lt` (`<`), `:lte` (`<=`) - Numeric/date comparisons
  - **Set operations**: `:in`, `:nin`, `:contains_all` - Membership testing with lists
  - **String matching**: `:starts_with` (`prefix*`), `:ends_with` (`*suffix`) - Pattern matching

  ## Field Path Resolution

  Field paths support dot notation for traversing associations:

  - `"status"` - Root field on the primary schema
  - `"organization.name"` - Field on a belongs_to or has_one association
  - `"tags.name"` - Field on a has_many or many_to_many association

  ## Association Join Behavior

  The Builder automatically determines when associations need to be joined:

  - **One-to-one joins** (belongs_to, has_one): No DISTINCT required
  - **One-to-many joins** (has_many, many_to_many): Automatically applies DISTINCT
  - **Join strategy**: Always uses LEFT JOIN to preserve records without associations

  ## Type Casting and Validation

  All field values are automatically cast to their Ecto schema types:

  - String values cast to appropriate numeric, date, or boolean types
  - List values for IN/NOT IN operations cast element-wise
  - Invalid values return `{:error, :invalid_value}`

  ## Performance Considerations

  - The Builder generates efficient SQL with proper indexing hints
  - Many-to-many joins automatically include DISTINCT to prevent duplicate rows
  - TSVector strategies provide ranking metadata for search result ordering
  - Field resolution is optimized for common access patterns

  ## Notes

  This module is designed for internal use within the Sifter library. Most users
  should interact with the higher-level `Sifter` module rather than calling
  the Builder directly. The Builder assumes well-formed AST input from the Parser
  and focuses on efficient query generation rather than input validation.
  """

  import Ecto.Query
  alias Sifter.AST

  @type meta :: %{
          uses_full_text?: boolean(),
          added_select_fields: [atom()],
          recommended_order: [{atom(), :asc | :desc}] | nil,
          warnings: [map()] | nil,
          assoc_contains_all: [map()] | nil
        }

  @default_meta %{
    uses_full_text?: false,
    added_select_fields: [],
    recommended_order: nil,
    warnings: [],
    assoc_contains_all: []
  }

  @spec apply(Ecto.Queryable.t(), AST.t(), keyword()) ::
          {:ok, Ecto.Query.t(), meta()}
          | {:ok, :no_predicates, Ecto.Query.t()}
          | {:error, {:builder, term()}}
  def apply(queryable, ast, opts) do
    query = Ecto.Queryable.to_query(queryable)

    options = Sifter.Options.resolve(opts)
    ft_fields = normalize_search_fields(opts[:search_fields])
    ft_strategy = opts[:search_strategy] || :ilike
    ft_column = opts[:search_fields_column] || :searchable

    root_schema =
      case opts[:schema] do
        nil ->
          case query.from do
            %{source: {_src, mod}} when is_atom(mod) -> mod
            _ -> raise ArgumentError, "Sifter.Ecto.Builder needs :schema option or a schema query"
          end

        mod ->
          mod
      end

    allow =
      if Keyword.has_key?(opts, :allowed_fields) do
        normalize_allowed_fields(opts[:allowed_fields])
      else
        %{allow_all?: true, allowed: MapSet.new(), mapping: %{}}
      end

    assoc_needed = ast_assoc_allowed?(ast, allow) or search_fields_assoc?(ft_fields)
    assoc_name = if assoc_needed, do: pick_first_assoc_allowed(ast, ft_fields, allow), else: nil

    {query1, related_schema, shape, many?} =
      maybe_join_once(query, root_schema, assoc_name)

    case compile_node(ast, root_schema, related_schema, allow, shape,
           options: options,
           search_fields: ft_fields,
           search_strategy: ft_strategy,
           search_fields_column: ft_column
         ) do
      {:ok, nil, _meta} ->
        q = if many?, do: distinct(query1, true), else: query1
        {:ok, :no_predicates, q}

      {:ok, dyn, meta} ->
        q2 =
          case shape do
            :root_only -> where(query1, [root], ^dyn)
            :with_assoc -> where(query1, [root, j], ^dyn)
          end

        q3 = apply_assoc_contains_all_aggregation(q2, meta, shape)

        q3 = if many?, do: distinct(q3, true), else: q3
        {:ok, q3, meta}

      {:error, reason} ->
        {:error, {:builder, reason}}
    end
  end

  defp maybe_join_once(query, _root_schema, nil),
    do: {query, nil, :root_only, false}

  defp maybe_join_once(query, root_schema, assoc_str) when is_binary(assoc_str) do
    assoc_atom = String.to_atom(assoc_str)

    case root_schema.__schema__(:association, assoc_atom) do
      %Ecto.Association.Has{related: rel, owner_key: owner_key, related_key: related_key} ->
        q =
          join(query, :left, [root], j in ^rel,
            on: field(j, ^related_key) == field(root, ^owner_key)
          )

        {q, rel, :with_assoc, true}

      %Ecto.Association.BelongsTo{related: rel, owner_key: owner_key, related_key: related_key} ->
        q =
          join(query, :left, [root], j in ^rel,
            on: field(root, ^owner_key) == field(j, ^related_key)
          )

        {q, rel, :with_assoc, false}

      %Ecto.Association.ManyToMany{related: rel} ->
        q = join(query, :left, [root], j in assoc(root, ^assoc_atom))
        {q, rel, :with_assoc, true}

      _ ->
        {query, nil, :root_only, false}
    end
  end

  defp pick_first_assoc_allowed(ast, ft, allow) do
    first_assoc_in_ast_allowed(ast, allow) || first_assoc_in_ft(ft)
  end

  defp ast_assoc_allowed?(%AST.Cmp{field_path: fp}, allow) when length(fp) > 1 do
    case resolve_allowed_path(fp, allow, unknown_field: :ignore) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp ast_assoc_allowed?(%AST.And{children: cs}, allow),
    do: Enum.any?(cs, &ast_assoc_allowed?(&1, allow))

  defp ast_assoc_allowed?(%AST.Or{children: cs}, allow),
    do: Enum.any?(cs, &ast_assoc_allowed?(&1, allow))

  defp ast_assoc_allowed?(%AST.Not{expr: e}, allow), do: ast_assoc_allowed?(e, allow)
  defp ast_assoc_allowed?(%AST.FullText{} = _ft, _), do: false
  defp ast_assoc_allowed?(_, _), do: false

  defp search_fields_assoc?(list) when is_list(list),
    do: Enum.any?(list, &String.contains?(&1, "."))

  defp search_fields_assoc?(_), do: false

  defp first_assoc_in_ast_allowed(%AST.Cmp{field_path: fp}, allow) when length(fp) > 1 do
    case resolve_allowed_path(fp, allow, unknown_field: :ignore) do
      {:ok, resolved} -> List.first(resolved)
      _ -> nil
    end
  end

  defp first_assoc_in_ast_allowed(%AST.And{children: cs}, allow),
    do: Enum.find_value(cs, &first_assoc_in_ast_allowed(&1, allow))

  defp first_assoc_in_ast_allowed(%AST.Or{children: cs}, allow),
    do: Enum.find_value(cs, &first_assoc_in_ast_allowed(&1, allow))

  defp first_assoc_in_ast_allowed(%AST.Not{expr: e}, allow),
    do: first_assoc_in_ast_allowed(e, allow)

  defp first_assoc_in_ast_allowed(_, _), do: nil

  defp first_assoc_in_ft(list) when is_list(list) do
    list
    |> Enum.find_value(fn path ->
      case String.split(path, ".", parts: 2) do
        [a, _] -> a
        _ -> nil
      end
    end)
  end

  defp first_assoc_in_ft(_), do: nil

  defp normalize_search_fields(nil), do: nil
  defp normalize_search_fields([]), do: []

  defp normalize_search_fields(fields) when is_list(fields) do
    Enum.map(fields, fn
      field when is_atom(field) -> Atom.to_string(field)
      field when is_binary(field) -> field
    end)
  end

  defp normalize_search_fields(field) when is_atom(field), do: [Atom.to_string(field)]
  defp normalize_search_fields(field) when is_binary(field), do: [field]

  defp compile_node(%AST.And{children: []}, _r, _rel, _allow, _shape, _opts),
    do: {:ok, nil, @default_meta}

  defp compile_node(%AST.And{children: cs}, r, rel, allow, shape, opts) do
    Enum.reduce_while(cs, {:ok, nil, @default_meta}, fn child, {:ok, acc, meta} ->
      case compile_node(child, r, rel, allow, shape, opts) do
        {:ok, d, m1} ->
          new_acc =
            cond do
              is_nil(d) -> acc
              is_nil(acc) -> d
              true -> and_dyn(acc, d, shape)
            end

          {:cont, {:ok, new_acc, merge_meta(meta, m1)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp compile_node(%AST.Or{children: []}, _r, _rel, _allow, _shape, _opts),
    do: {:ok, nil, @default_meta}

  defp compile_node(%AST.Or{children: cs}, r, rel, allow, shape, opts) do
    Enum.reduce_while(cs, {:ok, nil, @default_meta}, fn child, {:ok, acc, meta} ->
      case compile_node(child, r, rel, allow, shape, opts) do
        {:ok, d, m1} ->
          new_acc =
            cond do
              is_nil(d) -> acc
              is_nil(acc) -> d
              true -> or_dyn(acc, d, shape)
            end

          {:cont, {:ok, new_acc, merge_meta(meta, m1)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp compile_node(%AST.Not{expr: e}, r, rel, allow, shape, opts) do
    with {:ok, d, m} <- compile_node(e, r, rel, allow, shape, opts) do
      {:ok, if(is_nil(d), do: nil, else: not_dyn(d, shape)), m}
    end
  end

  defp compile_node(%AST.Cmp{} = cmp, r, rel, allow, shape, opts) do
    build_cmp(cmp, r, rel, allow, shape, opts)
  end

  defp compile_node(%AST.FullText{term: term}, r, rel, _allow, shape, opts) do
    ft_fields = opts[:search_fields]
    ft_strategy = opts[:search_strategy] || :ilike
    ft_column = opts[:search_fields_column] || :searchable
    options = opts[:options]

    sanitized_term = sanitize_term(term, options)

    tsquery_mode = determine_tsquery_mode(ft_strategy, options)

    case build_search(
           sanitized_term,
           ft_fields,
           ft_strategy,
           ft_column,
           r,
           rel,
           shape,
           tsquery_mode
         ) do
      {:ok, nil, meta} -> {:ok, nil, meta}
      {:ok, dyn, meta} -> {:ok, dyn, meta}
    end
  end

  defp and_dyn(a, b, :root_only), do: dynamic([root], ^a and ^b)
  defp and_dyn(a, b, :with_assoc), do: dynamic([root, j], ^a and ^b)
  defp or_dyn(a, b, :root_only), do: dynamic([root], ^a or ^b)
  defp or_dyn(a, b, :with_assoc), do: dynamic([root, j], ^a or ^b)
  defp not_dyn(d, :root_only), do: dynamic([root], not (^d))
  defp not_dyn(d, :with_assoc), do: dynamic([root, j], not (^d))

  defp merge_meta(a, b) do
    %{
      uses_full_text?: a.uses_full_text? or b.uses_full_text?,
      added_select_fields: Enum.uniq(a.added_select_fields ++ b.added_select_fields),
      recommended_order: b.recommended_order || a.recommended_order,
      warnings: (a[:warnings] || []) ++ (b[:warnings] || []),
      assoc_contains_all: (a[:assoc_contains_all] || []) ++ (b[:assoc_contains_all] || [])
    }
  end

  defp handle_contains_all(:contains_all, binding, field_atom, type, casted, shape, resolved_fp) do
    case {binding, type, shape} do
      {:root, {:array, inner}, shape} ->
        dyn = contains_all_array_dyn(:root, field_atom, casted, inner, shape)
        {:contains_all_handled, {:ok, dyn, @default_meta}}

      {:assoc, _type, :with_assoc} ->
        dyn = dynamic([_root, j], field(j, ^field_atom) in ^casted)
        unique_count = length(Enum.uniq(casted))

        meta = %{
          @default_meta
          | assoc_contains_all: [%{field_atom: field_atom, count: unique_count}]
        }

        {:contains_all_handled, {:ok, dyn, meta}}

      {:root, _not_array, shape} ->
        dyn =
          case shape do
            :root_only -> dynamic([root], field(root, ^field_atom) in ^casted)
            :with_assoc -> dynamic([root, _j], field(root, ^field_atom) in ^casted)
          end

        warning = %{
          type: :degraded_contains_all,
          field: Enum.join(resolved_fp, "."),
          op_used: :in
        }

        meta = Map.update!(@default_meta, :warnings, &[warning | &1])
        {:contains_all_handled, {:ok, dyn, meta}}
    end
  end

  defp handle_contains_all(_op, _binding, _field_atom, _type, _casted, _shape, _resolved_fp) do
    :not_contains_all
  end

  defp contains_all_array_dyn(:root, field_atom, casted, _inner, :root_only) do
    dynamic([root], fragment("? @> ?::text[]", field(root, ^field_atom), ^casted))
  end

  defp contains_all_array_dyn(:root, field_atom, casted, _inner, :with_assoc) do
    dynamic([root, _j], fragment("? @> ?::text[]", field(root, ^field_atom), ^casted))
  end

  defp apply_assoc_contains_all_aggregation(query, meta, shape) do
    assoc_contains_all = meta[:assoc_contains_all] || []

    if Enum.empty?(assoc_contains_all) do
      query
    else
      case shape do
        :with_assoc ->
          root_pk = get_primary_key_field(query)

          having_conditions =
            Enum.map(assoc_contains_all, fn %{field_atom: field_atom, count: count} ->
              dynamic([_root, j], count(field(j, ^field_atom), :distinct) == ^count)
            end)

          combined_having =
            case having_conditions do
              [] ->
                nil

              [single] ->
                single

              multiple ->
                Enum.reduce(multiple, fn having, acc ->
                  dynamic([root, j], ^acc and ^having)
                end)
            end

          query
          |> group_by([root, _j], field(root, ^root_pk))
          |> having([_root, j], ^combined_having)

        :root_only ->
          query
      end
    end
  end

  defp get_primary_key_field(query) do
    case query.from do
      %{source: {_table, schema}} when is_atom(schema) ->
        case schema.__schema__(:primary_key) do
          [pk | _] -> pk
          [] -> :id
        end

      _ ->
        :id
    end
  end

  defp build_cmp(
         %AST.Cmp{field_path: fp, op: op, value: val},
         root_schema,
         rel_schema,
         allow,
         shape,
         opts
       ) do
    options = opts[:options]

    with {:ok, resolved_fp} <-
           resolve_allowed_path(fp, allow, %{unknown_field: options.unknown_field}),
         {:ok, binding, field_atom, type} <-
           resolve_field(resolved_fp, root_schema, rel_schema, %{
             unknown_field: options.unknown_field,
             original_path: fp
           }),
         cast <- cast_value(type, op, val) do
      case cast do
        {:date_only, op, d, datetime_type} ->
          {:ok, date_only_dyn(binding, field_atom, op, d, datetime_type, shape), @default_meta}

        {:ok, casted} ->
          case handle_contains_all(op, binding, field_atom, type, casted, shape, resolved_fp) do
            {:contains_all_handled, result} ->
              result

            :not_contains_all ->
              {:ok, cmp_dyn(binding, field_atom, op, casted, shape), @default_meta}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ignore, warning} ->
        {:ok, nil, Map.put(@default_meta, :warnings, [warning])}

      :ignore ->
        {:ok, nil, @default_meta}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cmp_dyn(:root, f, :eq, v, :root_only), do: dynamic([root], field(root, ^f) == ^v)
  defp cmp_dyn(:root, f, :neq, v, :root_only), do: dynamic([root], field(root, ^f) != ^v)
  defp cmp_dyn(:root, f, :gt, v, :root_only), do: dynamic([root], field(root, ^f) > ^v)
  defp cmp_dyn(:root, f, :gte, v, :root_only), do: dynamic([root], field(root, ^f) >= ^v)
  defp cmp_dyn(:root, f, :lt, v, :root_only), do: dynamic([root], field(root, ^f) < ^v)
  defp cmp_dyn(:root, f, :lte, v, :root_only), do: dynamic([root], field(root, ^f) <= ^v)
  defp cmp_dyn(:root, f, :in, v, :root_only), do: dynamic([root], field(root, ^f) in ^v)
  defp cmp_dyn(:root, f, :nin, v, :root_only), do: dynamic([root], field(root, ^f) not in ^v)

  defp cmp_dyn(:root, f, :starts_with, v, :root_only),
    do: dynamic([root], ilike(field(root, ^f), ^(escape_like(v) <> "%")))

  defp cmp_dyn(:root, f, :ends_with, v, :root_only),
    do: dynamic([root], ilike(field(root, ^f), ^("%" <> escape_like(v))))

  defp cmp_dyn(:assoc, f, :eq, v, :with_assoc), do: dynamic([_root, j], field(j, ^f) == ^v)
  defp cmp_dyn(:assoc, f, :neq, v, :with_assoc), do: dynamic([_root, j], field(j, ^f) != ^v)
  defp cmp_dyn(:assoc, f, :gt, v, :with_assoc), do: dynamic([_root, j], field(j, ^f) > ^v)
  defp cmp_dyn(:assoc, f, :gte, v, :with_assoc), do: dynamic([_root, j], field(j, ^f) >= ^v)
  defp cmp_dyn(:assoc, f, :lt, v, :with_assoc), do: dynamic([_root, j], field(j, ^f) < ^v)
  defp cmp_dyn(:assoc, f, :lte, v, :with_assoc), do: dynamic([_root, j], field(j, ^f) <= ^v)
  defp cmp_dyn(:assoc, f, :in, v, :with_assoc), do: dynamic([_root, j], field(j, ^f) in ^v)
  defp cmp_dyn(:assoc, f, :nin, v, :with_assoc), do: dynamic([_root, j], field(j, ^f) not in ^v)

  defp cmp_dyn(:assoc, f, :starts_with, v, :with_assoc),
    do: dynamic([_root, j], ilike(field(j, ^f), ^(escape_like(v) <> "%")))

  defp cmp_dyn(:assoc, f, :ends_with, v, :with_assoc),
    do: dynamic([_root, j], ilike(field(j, ^f), ^("%" <> escape_like(v))))

  defp cmp_dyn(:root, f, op, v, :with_assoc) do
    root_dyn = cmp_dyn(:root, f, op, v, :root_only)
    dynamic([_root, j], ^root_dyn)
  end

  defp date_only_dyn(kind, f, op, %Date{} = d, datetime_type, shape) do
    {start_dt, next_dt} = create_datetime_boundaries(d, datetime_type)

    case {kind, shape, op} do
      {:root, :root_only, :eq} ->
        dynamic([root], field(root, ^f) >= ^start_dt and field(root, ^f) < ^next_dt)

      {:root, :root_only, :gte} ->
        dynamic([root], field(root, ^f) >= ^start_dt)

      {:root, :root_only, :gt} ->
        dynamic([root], field(root, ^f) >= ^next_dt)

      {:root, :root_only, :lte} ->
        dynamic([root], field(root, ^f) < ^next_dt)

      {:root, :root_only, :lt} ->
        dynamic([root], field(root, ^f) < ^start_dt)

      {:root, :with_assoc, :eq} ->
        dynamic([root, _j], field(root, ^f) >= ^start_dt and field(root, ^f) < ^next_dt)

      {:root, :with_assoc, :gte} ->
        dynamic([root, _j], field(root, ^f) >= ^start_dt)

      {:root, :with_assoc, :gt} ->
        dynamic([root, _j], field(root, ^f) >= ^next_dt)

      {:root, :with_assoc, :lte} ->
        dynamic([root, _j], field(root, ^f) < ^next_dt)

      {:root, :with_assoc, :lt} ->
        dynamic([root, _j], field(root, ^f) < ^start_dt)

      {:assoc, :with_assoc, :eq} ->
        dynamic([_root, j], field(j, ^f) >= ^start_dt and field(j, ^f) < ^next_dt)

      {:assoc, :with_assoc, :gte} ->
        dynamic([_root, j], field(j, ^f) >= ^start_dt)

      {:assoc, :with_assoc, :gt} ->
        dynamic([_root, j], field(j, ^f) >= ^next_dt)

      {:assoc, :with_assoc, :lte} ->
        dynamic([_root, j], field(j, ^f) < ^next_dt)

      {:assoc, :with_assoc, :lt} ->
        dynamic([_root, j], field(j, ^f) < ^start_dt)

      other ->
        raise ArgumentError, "date-only not supported for #{inspect(other)}"
    end
  end

  defp create_datetime_boundaries(%Date{} = d, datetime_type) do
    case datetime_type do
      :utc_datetime ->
        start_dt = DateTime.new!(d, ~T[00:00:00], "Etc/UTC") |> DateTime.truncate(:second)

        next_dt =
          d |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.truncate(:second)

        {start_dt, next_dt}

      :utc_datetime_usec ->
        start_dt = DateTime.new!(d, ~T[00:00:00.000000], "Etc/UTC")
        next_dt = d |> Date.add(1) |> DateTime.new!(~T[00:00:00.000000], "Etc/UTC")
        {start_dt, next_dt}

      :naive_datetime ->
        start_dt = NaiveDateTime.new!(d, ~T[00:00:00]) |> NaiveDateTime.truncate(:second)

        next_dt =
          d |> Date.add(1) |> NaiveDateTime.new!(~T[00:00:00]) |> NaiveDateTime.truncate(:second)

        {start_dt, next_dt}

      :naive_datetime_usec ->
        start_dt = NaiveDateTime.new!(d, ~T[00:00:00.000000])
        next_dt = d |> Date.add(1) |> NaiveDateTime.new!(~T[00:00:00.000000])
        {start_dt, next_dt}

      other ->
        raise ArgumentError, "Unsupported datetime type for date-only: #{inspect(other)}"
    end
  end

  defp build_search(_term, nil, _st, _col, _r, _rel, _shape, _mode),
    do: {:ok, nil, @default_meta}

  defp build_search(_term, [], _st, _col, _r, _rel, _shape, _mode),
    do: {:ok, nil, @default_meta}

  defp build_search(term, _fields, {:column, {cfg, col}}, _ftcol, _r, _rel, shape, tsquery_mode) do
    dyn = tsquery_fragment(cfg, col, term, shape, tsquery_mode)

    meta = %{
      uses_full_text?: true,
      added_select_fields: [:search_rank],
      recommended_order: [search_rank: :desc],
      warnings: []
    }

    {:ok, dyn, meta}
  end

  defp build_search(term, fields, :ilike, _col, root_schema, rel_schema, shape, _tsquery_mode)
       when is_list(fields) do
    parts =
      fields
      |> Enum.map(&String.split(&1, ".", parts: 2))
      |> Enum.map(fn
        [f] ->
          with {:ok, fa} <- root_text_field(root_schema, f) do
            case shape do
              :root_only ->
                dynamic([root], ilike(field(root, ^fa), ^("%" <> escape_like(term) <> "%")))

              :with_assoc ->
                dynamic([root, _j], ilike(field(root, ^fa), ^("%" <> escape_like(term) <> "%")))
            end
          else
            :ignore -> nil
          end

        [_a, f] when not is_nil(rel_schema) ->
          with {:ok, fa} <- assoc_text_field(rel_schema, f) do
            dynamic([_root, j], ilike(field(j, ^fa), ^("%" <> escape_like(term) <> "%")))
          else
            :ignore -> nil
          end

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    dyn =
      case parts do
        [] -> nil
        [d] -> d
        many -> Enum.reduce(many, fn d, acc -> or_dyn(acc, d, shape) end)
      end

    {:ok, dyn,
     %{
       uses_full_text?: not is_nil(dyn),
       added_select_fields: [],
       recommended_order: nil,
       warnings: []
     }}
  end

  defp build_search(
         term,
         fields,
         {:tsquery, cfg},
         _col,
         root_schema,
         rel_schema,
         shape,
         tsquery_mode
       )
       when is_list(fields) do
    parts =
      fields
      |> Enum.map(&String.split(&1, ".", parts: 2))
      |> Enum.map(fn
        [f] ->
          with {:ok, fa} <- root_text_field(root_schema, f) do
            tsvector_fragment(cfg, fa, term, shape, tsquery_mode)
          else
            :ignore -> nil
          end

        [_a, f] when not is_nil(rel_schema) ->
          with {:ok, fa} <- assoc_text_field(rel_schema, f) do
            tsvector_fragment(cfg, fa, term, :assoc, tsquery_mode)
          else
            :ignore -> nil
          end

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    dyn =
      case parts do
        [] -> nil
        [d] -> d
        many -> Enum.reduce(many, fn d, acc -> or_dyn(acc, d, shape) end)
      end

    meta = %{
      uses_full_text?: not is_nil(dyn),
      added_select_fields: [],
      recommended_order: nil,
      warnings: []
    }

    {:ok, dyn, meta}
  end

  defp build_search(
         term,
         fields,
         {:tsquery_raw, cfg},
         _col,
         root_schema,
         rel_schema,
         shape,
         tsquery_mode
       )
       when is_list(fields) do
    parts =
      fields
      |> Enum.map(&String.split(&1, ".", parts: 2))
      |> Enum.map(fn
        [f] ->
          with {:ok, fa} <- root_text_field(root_schema, f) do
            tsvector_fragment(cfg, fa, term, shape, tsquery_mode)
          else
            :ignore -> nil
          end

        [_a, f] when not is_nil(rel_schema) ->
          with {:ok, fa} <- assoc_text_field(rel_schema, f) do
            tsvector_fragment(cfg, fa, term, :assoc, tsquery_mode)
          else
            :ignore -> nil
          end

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    dyn =
      case parts do
        [] -> nil
        [d] -> d
        many -> Enum.reduce(many, fn d, acc -> or_dyn(acc, d, shape) end)
      end

    meta = %{
      uses_full_text?: not is_nil(dyn),
      added_select_fields: [],
      recommended_order: nil,
      warnings: []
    }

    {:ok, dyn, meta}
  end

  defp normalize_allowed_fields([]), do: %{allow_all?: true, allowed: MapSet.new(), mapping: %{}}

  defp normalize_allowed_fields(list) when is_list(list) do
    Enum.reduce(list, %{allow_all?: false, allowed: MapSet.new(), mapping: %{}}, fn
      %{:as => as, :field => field}, acc when is_binary(as) and is_binary(field) ->
        %{acc | allowed: MapSet.put(acc.allowed, as), mapping: Map.put(acc.mapping, as, field)}

      bin, acc when is_binary(bin) ->
        %{acc | allowed: MapSet.put(acc.allowed, bin)}

      atom, acc when is_atom(atom) ->
        %{acc | allowed: MapSet.put(acc.allowed, Atom.to_string(atom))}

      _other, acc ->
        acc
    end)
  end

  defp resolve_allowed_path(fp, %{allow_all?: true}, _opts), do: {:ok, fp}

  defp resolve_allowed_path(fp, %{allow_all?: false, allowed: allowed, mapping: mapping}, opts) do
    as = Enum.join(fp, ".")

    cond do
      Map.has_key?(mapping, as) ->
        {:ok, String.split(mapping[as], ".", parts: :infinity)}

      MapSet.member?(allowed, as) ->
        {:ok, fp}

      MapSet.member?(allowed, List.first(fp)) and length(fp) == 1 ->
        {:ok, fp}

      true ->
        handle_unknown_field(fp, opts)
    end
  end

  defp resolve_field([field], root_schema, _rel_schema, opts),
    do: do_resolve_field(:root, field, root_schema, opts)

  defp resolve_field([_assoc, _field], _root_schema, nil, _opts), do: :ignore

  defp resolve_field([_assoc, field], _root_schema, rel_schema, opts),
    do: do_resolve_field(:assoc, field, rel_schema, opts)

  defp resolve_field(path, _root_schema, _rel_schema, opts) when length(path) > 2,
    do: handle_unknown_field(path, opts)

  defp do_resolve_field(kind, field, schema, opts) do
    f = String.to_atom(field)

    if f in schema.__schema__(:fields) do
      {:ok, kind, f, schema.__schema__(:type, f)}
    else
      handle_unknown_field([field], opts)
    end
  end

  defp handle_unknown_field(path, %{unknown_field: :error}),
    do: {:error, {:unknown_field, Enum.join(List.wrap(path), ".")}}

  defp handle_unknown_field(path, %{unknown_field: :warn}) do
    {:ignore, %{type: :unknown_field, path: Enum.join(List.wrap(path), ".")}}
  end

  defp handle_unknown_field(_path, _), do: :ignore

  defp cast_value({:array, inner}, :contains_all, list) when is_list(list) do
    cast_list(inner, list)
  end

  defp cast_value(type, :contains_all, list) when is_list(list) do
    cast_list(type, list)
  end

  defp cast_value(type, :in, list) when is_list(list), do: cast_list(type, list)
  defp cast_value(type, :nin, list) when is_list(list), do: cast_list(type, list)

  defp cast_value(_type, op, v) when op in [:starts_with, :ends_with] and is_binary(v),
    do: {:ok, v}

  defp cast_value(type, op, v) do
    cast_value_with_dateonly(type, op, v)
  end

  defp cast_value_with_dateonly(type, op, v) do
    case {type, v} do
      {t, val}
      when t in [:utc_datetime, :naive_datetime, :utc_datetime_usec, :naive_datetime_usec] and
             is_binary(val) ->
        case Date.from_iso8601(val) do
          {:ok, d} -> {:date_only, op, d, t}
          _ -> do_strict_cast(type, val)
        end

      _ ->
        do_strict_cast(type, v)
    end
  end

  defp do_strict_cast(type, v) do
    case Ecto.Type.cast(type, v) do
      {:ok, casted} -> {:ok, casted}
      :error -> {:error, :invalid_value}
    end
  end

  defp cast_list(type, list) do
    list
    |> Enum.map(&Ecto.Type.cast(type, &1))
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, v}, {:ok, acc} -> {:cont, {:ok, [v | acc]}}
      :error, _ -> {:halt, {:error, :invalid_value}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  defp root_text_field(schema, field) do
    f = String.to_atom(field)

    if f in schema.__schema__(:fields) and schema.__schema__(:type, f) in [:string, :text],
      do: {:ok, f},
      else: :ignore
  end

  defp assoc_text_field(schema, field), do: root_text_field(schema, field)

  defp escape_like(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp sanitize_term(term, options) do
    case options.full_text_sanitizer do
      {module, function, args} ->
        Kernel.apply(module, function, [term | args])

      sanitizer_fun when is_function(sanitizer_fun, 1) ->
        sanitizer_fun.(term)

      nil ->
        # Use default sanitizer based on tsquery mode
        case options.tsquery_mode do
          :plainto -> Sifter.FullText.Sanitizers.Basic.sanitize_plainto(term)
          :raw -> Sifter.FullText.Sanitizers.Strict.sanitize_tsquery(term)
        end
    end
  end

  defp determine_tsquery_mode(ft_strategy, options) do
    case ft_strategy do
      {:tsquery, _cfg} -> :plainto
      {:tsquery_raw, _cfg} -> :raw
      {:column, _} -> options.tsquery_mode
      _ -> :plainto
    end
  end

  defp tsquery_fragment(cfg, col_binding, term, shape, mode) do
    cfg = to_string(cfg)

    case {shape, mode} do
      {:root_only, :plainto} ->
        dynamic(
          [root],
          fragment(
            "? @@ plainto_tsquery(?::regconfig, ?)",
            field(root, ^col_binding),
            type(^cfg, :string),
            ^term
          )
        )

      {:root_only, :raw} ->
        dynamic(
          [root],
          fragment(
            "? @@ to_tsquery(?::regconfig, ?)",
            field(root, ^col_binding),
            type(^cfg, :string),
            ^term
          )
        )

      {:with_assoc, :plainto} ->
        dynamic(
          [root, _j],
          fragment(
            "? @@ plainto_tsquery(?::regconfig, ?)",
            field(root, ^col_binding),
            type(^cfg, :string),
            ^term
          )
        )

      {:with_assoc, :raw} ->
        dynamic(
          [root, _j],
          fragment(
            "? @@ to_tsquery(?::regconfig, ?)",
            field(root, ^col_binding),
            type(^cfg, :string),
            ^term
          )
        )
    end
  end

  defp tsvector_fragment(cfg, field_binding, term, shape, mode) do
    cfg = to_string(cfg)

    case {shape, mode} do
      {:root_only, :plainto} ->
        dynamic(
          [root],
          fragment(
            "to_tsvector(?::regconfig, coalesce(?, '')) @@ plainto_tsquery(?::regconfig, ?)",
            type(^cfg, :string),
            field(root, ^field_binding),
            type(^cfg, :string),
            ^term
          )
        )

      {:root_only, :raw} ->
        dynamic(
          [root],
          fragment(
            "to_tsvector(?::regconfig, coalesce(?, '')) @@ to_tsquery(?::regconfig, ?)",
            type(^cfg, :string),
            field(root, ^field_binding),
            type(^cfg, :string),
            ^term
          )
        )

      {:with_assoc, :plainto} ->
        dynamic(
          [root, _j],
          fragment(
            "to_tsvector(?::regconfig, coalesce(?, '')) @@ plainto_tsquery(?::regconfig, ?)",
            type(^cfg, :string),
            field(root, ^field_binding),
            type(^cfg, :string),
            ^term
          )
        )

      {:with_assoc, :raw} ->
        dynamic(
          [root, _j],
          fragment(
            "to_tsvector(?::regconfig, coalesce(?, '')) @@ to_tsquery(?::regconfig, ?)",
            type(^cfg, :string),
            field(root, ^field_binding),
            type(^cfg, :string),
            ^term
          )
        )

      {:assoc, :plainto} ->
        dynamic(
          [_root, j],
          fragment(
            "to_tsvector(?::regconfig, coalesce(?, '')) @@ plainto_tsquery(?::regconfig, ?)",
            type(^cfg, :string),
            field(j, ^field_binding),
            type(^cfg, :string),
            ^term
          )
        )

      {:assoc, :raw} ->
        dynamic(
          [_root, j],
          fragment(
            "to_tsvector(?::regconfig, coalesce(?, '')) @@ to_tsquery(?::regconfig, ?)",
            type(^cfg, :string),
            field(j, ^field_binding),
            type(^cfg, :string),
            ^term
          )
        )
    end
  end
end
