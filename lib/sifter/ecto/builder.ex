defmodule Sifter.Ecto.Builder do
  @moduledoc """
  The Builder transforms parsed `Sifter.AST` nodes into Ecto query expressions.

  This module serves as the bridge between Sifter's abstract syntax tree representation
  and Ecto's query DSL, generating dynamic SQL fragments that can be applied to Ecto queries.
  The Builder handles field validation, type casting, association joins, and full-text search
  strategies while providing comprehensive metadata about the generated query.
  """

  import Ecto.Query
  alias Sifter.AST

  @type meta :: %{
          uses_full_text?: boolean(),
          added_select_fields: [atom()],
          recommended_order: [{atom(), :asc | :desc}] | nil,
          warnings: [map()] | nil
        }

  @default_meta %{
    uses_full_text?: false,
    added_select_fields: [],
    recommended_order: nil,
    warnings: []
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

    need_alias? =
      needs_root_alias?(ast, allow) or needs_root_alias_for_assoc?(root_schema, assoc_name)

    query = if need_alias?, do: from(root in query, as: :root), else: query

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

        q2 = if many?, do: distinct(q2, true), else: q2
        {:ok, q2, meta}

      {:error, reason} ->
        {:error, {:builder, reason}}
    end
  end

  defp needs_root_alias?(ast, allow), do: contains_all_assoc?(ast, allow)

  defp needs_root_alias_for_assoc?(_root_schema, nil), do: false

  defp needs_root_alias_for_assoc?(root_schema, assoc_str) when is_binary(assoc_str) do
    assoc_atom = String.to_atom(assoc_str)

    case root_schema.__schema__(:association, assoc_atom) do
      %Ecto.Association.ManyToMany{} -> true
      _ -> false
    end
  end

  defp contains_all_assoc?(%AST.Cmp{op: :contains_all, field_path: fp}, allow) do
    case resolve_allowed_path(fp, allow, unknown_field: :ignore) do
      {:ok, resolved} when length(resolved) > 1 -> true
      _ -> false
    end
  end

  defp contains_all_assoc?(%AST.And{children: cs}, allow),
    do: Enum.any?(cs, &contains_all_assoc?(&1, allow))

  defp contains_all_assoc?(%AST.Or{children: cs}, allow),
    do: Enum.any?(cs, &contains_all_assoc?(&1, allow))

  defp contains_all_assoc?(%AST.Not{expr: e}, allow), do: contains_all_assoc?(e, allow)
  defp contains_all_assoc?(_, _), do: false

  defp maybe_join_once(query, _root_schema, nil),
    do: {query, nil, :root_only, false}

  defp maybe_join_once(query, root_schema, assoc_str) when is_binary(assoc_str) do
    assoc_atom = String.to_atom(assoc_str)

    case root_schema.__schema__(:association, assoc_atom) do
      %Ecto.Association.Has{related: rel, owner_key: owner_key, related_key: related_key} ->
        rel_q = Ecto.Queryable.to_query(rel)

        q =
          join(query, :left, [root], j in subquery(rel_q),
            on: field(j, ^related_key) == field(root, ^owner_key)
          )

        {q, rel, :with_assoc, true}

      %Ecto.Association.BelongsTo{related: rel, owner_key: owner_key, related_key: related_key} ->
        rel_q = Ecto.Queryable.to_query(rel)

        q =
          join(query, :left, [root], j in subquery(rel_q),
            on: field(root, ^owner_key) == field(j, ^related_key)
          )

        {q, rel, :with_assoc, false}

      %Ecto.Association.ManyToMany{} = a ->
        rel = a.related
        jt = a.join_through
        owner_mod = a.owner

        owner_pk = owner_mod.__schema__(:primary_key) |> List.first()
        related_pk = rel.__schema__(:primary_key) |> List.first()

        {owner_fk, rel_fk} = m2m_fk_columns(a, owner_mod, rel)

        rel_q = Ecto.Queryable.to_query(rel)
        jt_q = Ecto.Queryable.to_query(jt)

        sub =
          rel_q
          |> join(:inner, [j], jt0 in subquery(jt_q),
            on: field(jt0, ^rel_fk) == field(j, ^related_pk)
          )
          |> where([_j, jt0], field(jt0, ^owner_fk) == field(parent_as(:root), ^owner_pk))
          |> select([j, _jt0], j)

        q = join(query, :left_lateral, [root], j in subquery(sub), on: true)

        {q, rel, :with_assoc, true}

      _ ->
        {query, nil, :root_only, false}
    end
  end

  defp m2m_fk_columns(%Ecto.Association.ManyToMany{join_keys: join_keys} = _a, owner_mod, rel) do
    cond do
      Keyword.has_key?(join_keys, :source) and Keyword.has_key?(join_keys, :destination) ->
        {Keyword.fetch!(join_keys, :source), Keyword.fetch!(join_keys, :destination)}

      true ->
        owner_src = owner_mod.__schema__(:source) |> singular_guess()
        related_src = rel.__schema__(:source) |> singular_guess()

        keys = Keyword.keys(join_keys)

        owner_fk =
          Enum.find(keys, fn k ->
            s = Atom.to_string(k)
            String.contains?(s, owner_src <> "_") or String.starts_with?(s, owner_src)
          end) || hd(keys)

        rel_fk =
          Enum.find(keys, fn k ->
            k != owner_fk and
              (
                s = Atom.to_string(k)
                String.contains?(s, related_src <> "_") or String.starts_with?(s, related_src)
              )
          end) || (keys -- [owner_fk]) |> hd()

        {owner_fk, rel_fk}
    end
  end

  defp singular_guess(s) do
    if String.ends_with?(s, "s"), do: String.trim_trailing(s, "s"), else: s
  end

  defp pick_first_assoc_allowed(ast, ft, allow),
    do: first_assoc_in_ast_allowed(ast, allow) || first_assoc_in_ft(ft)

  defp ast_assoc_allowed?(%AST.Cmp{field_path: fp}, allow) do
    case resolve_allowed_path(fp, allow, unknown_field: :ignore) do
      {:ok, resolved_fp} when length(resolved_fp) > 1 -> true
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

  defp first_assoc_in_ast_allowed(%AST.Cmp{field_path: fp}, allow) do
    case resolve_allowed_path(fp, allow, unknown_field: :ignore) do
      {:ok, resolved} when length(resolved) > 1 -> List.first(resolved)
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

  defp is_null_dyn(:root, f, :root_only), do: dynamic([root], is_nil(field(root, ^f)))
  defp is_null_dyn(:root, f, :with_assoc), do: dynamic([root, _j], is_nil(field(root, ^f)))
  defp is_null_dyn(:assoc, f, :with_assoc), do: dynamic([_root, j], is_nil(field(j, ^f)))

  defp not_null_dyn(:root, f, :root_only), do: dynamic([root], not is_nil(field(root, ^f)))
  defp not_null_dyn(:root, f, :with_assoc), do: dynamic([root, _j], not is_nil(field(root, ^f)))
  defp not_null_dyn(:assoc, f, :with_assoc), do: dynamic([_root, j], not is_nil(field(j, ^f)))

  defp merge_meta(a, b) do
    %{
      uses_full_text?: a.uses_full_text? or b.uses_full_text?,
      added_select_fields: Enum.uniq(a.added_select_fields ++ b.added_select_fields),
      recommended_order: b.recommended_order || a.recommended_order,
      warnings: (a[:warnings] || []) ++ (b[:warnings] || [])
    }
  end

  defp handle_contains_all(
         :contains_all,
         binding,
         field_atom,
         type,
         casted,
         shape,
         resolved_fp,
         root_schema
       ) do
    case {binding, type} do
      {:root, {:array, _inner}} ->
        dyn = contains_all_array_dyn(:root, field_atom, casted, shape)
        {:contains_all_handled, {:ok, dyn, @default_meta}}

      {:assoc, _type} ->
        [assoc_name | _] = resolved_fp
        assoc_atom = String.to_atom(assoc_name)
        dyn = assoc_contains_all_dyn(root_schema, assoc_atom, field_atom, casted)
        {:contains_all_handled, {:ok, dyn, @default_meta}}

      {:root, _not_array} ->
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

  defp handle_contains_all(_op, _binding, _field_atom, _type, _casted, _shape, _fp, _rs),
    do: :not_contains_all

  defp contains_all_array_dyn(:root, field_atom, casted, :root_only) do
    dynamic([root], fragment("? @> ?::text[]", field(root, ^field_atom), ^casted))
  end

  defp contains_all_array_dyn(:root, field_atom, casted, :with_assoc) do
    dynamic([root, _j], fragment("? @> ?::text[]", field(root, ^field_atom), ^casted))
  end

  defp assoc_contains_all_dyn(root_schema, assoc_atom, field_atom, values) when is_list(values) do
    needed = values |> Enum.uniq() |> length()

    case root_schema.__schema__(:association, assoc_atom) do
      %Ecto.Association.Has{related: rel, owner_key: owner_key, related_key: related_key} ->
        rel_q =
          rel
          |> Ecto.Queryable.to_query()
          |> where([j], field(j, ^related_key) == field(parent_as(:root), ^owner_key))
          |> where([j], field(j, ^field_atom) in ^values)
          |> select([j], field(j, ^field_atom))
          |> distinct(true)

        dynamic([root], fragment("SELECT count(*) FROM (?) AS s", subquery(rel_q)) == ^needed)

      %Ecto.Association.BelongsTo{related: rel, owner_key: owner_key, related_key: related_key} ->
        rel_q =
          rel
          |> Ecto.Queryable.to_query()
          |> where([j], field(parent_as(:root), ^owner_key) == field(j, ^related_key))
          |> where([j], field(j, ^field_atom) in ^values)
          |> select([j], field(j, ^field_atom))
          |> distinct(true)

        dynamic([root], fragment("SELECT count(*) FROM (?) AS s", subquery(rel_q)) == ^needed)

      %Ecto.Association.ManyToMany{} = a ->
        rel = a.related
        jt = a.join_through
        owner_mod = a.owner

        owner_pk = owner_mod.__schema__(:primary_key) |> List.first()
        related_pk = rel.__schema__(:primary_key) |> List.first()

        {owner_fk, rel_fk} = m2m_fk_columns(a, owner_mod, rel)

        rel_q = Ecto.Queryable.to_query(rel)
        jt_q = Ecto.Queryable.to_query(jt)

        sub =
          rel_q
          |> join(:inner, [j], jt0 in subquery(jt_q),
            on: field(jt0, ^rel_fk) == field(j, ^related_pk)
          )
          |> where([_j, jt0], field(jt0, ^owner_fk) == field(parent_as(:root), ^owner_pk))
          |> where([j, _jt0], field(j, ^field_atom) in ^values)
          |> select([j, _jt0], field(j, ^field_atom))
          |> distinct(true)

        dynamic([root], fragment("SELECT count(*) FROM (?) AS s", subquery(sub)) == ^needed)

      other ->
        raise ArgumentError,
              "CONTAINS_ALL unsupported on association #{inspect(assoc_atom)}: #{inspect(other)}"
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
          case {op, casted} do
            {op, nil} when op in [:gt, :gte, :lt, :lte] ->
              {:error, {:invalid_null_comparison, op}}

            {:in, list} when is_list(list) ->
              if Enum.any?(list, &is_nil/1) do
                {nonnull, _} = Enum.split_with(list, &(!is_nil(&1)))

                d_in =
                  if nonnull == [] do
                    nil
                  else
                    cmp_dyn(binding, field_atom, :in, nonnull, shape)
                  end

                d_null = is_null_dyn(binding, field_atom, shape)

                dyn = if d_in, do: or_dyn(d_in, d_null, shape), else: d_null
                {:ok, dyn, @default_meta}
              else
                case handle_contains_all(
                       op,
                       binding,
                       field_atom,
                       type,
                       casted,
                       shape,
                       resolved_fp,
                       root_schema
                     ) do
                  {:contains_all_handled, result} ->
                    result

                  :not_contains_all ->
                    {:ok, cmp_dyn(binding, field_atom, op, casted, shape), @default_meta}
                end
              end

            {:nin, list} when is_list(list) ->
              if Enum.any?(list, &is_nil/1) do
                {nonnull, _} = Enum.split_with(list, &(!is_nil(&1)))

                d_not_in =
                  if nonnull == [] do
                    nil
                  else
                    cmp_dyn(binding, field_atom, :nin, nonnull, shape)
                  end

                d_not_null = not_null_dyn(binding, field_atom, shape)
                dyn = if d_not_in, do: and_dyn(d_not_in, d_not_null, shape), else: d_not_null
                {:ok, dyn, @default_meta}
              else
                case handle_contains_all(
                       op,
                       binding,
                       field_atom,
                       type,
                       casted,
                       shape,
                       resolved_fp,
                       root_schema
                     ) do
                  {:contains_all_handled, result} ->
                    result

                  :not_contains_all ->
                    {:ok, cmp_dyn(binding, field_atom, op, casted, shape), @default_meta}
                end
              end

            _ ->
              case handle_contains_all(
                     op,
                     binding,
                     field_atom,
                     type,
                     casted,
                     shape,
                     resolved_fp,
                     root_schema
                   ) do
                {:contains_all_handled, result} ->
                  result

                :not_contains_all ->
                  {:ok, cmp_dyn(binding, field_atom, op, casted, shape), @default_meta}
              end
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ignore, warning} -> {:ok, nil, Map.put(@default_meta, :warnings, [warning])}
      :ignore -> {:ok, nil, @default_meta}
      {:error, reason} -> {:error, reason}
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

  defp build_search(_term, nil, _st, _col, _r, _rel, _shape, _mode), do: {:ok, nil, @default_meta}
  defp build_search(_term, [], _st, _col, _r, _rel, _shape, _mode), do: {:ok, nil, @default_meta}

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

  defp build_search(term, fields, :ilike, _col, root_schema, rel_schema, shape, _mode)
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

    {:ok, dyn,
     %{
       uses_full_text?: not is_nil(dyn),
       added_select_fields: [],
       recommended_order: nil,
       warnings: []
     }}
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
      Map.has_key?(mapping, as) -> {:ok, String.split(mapping[as], ".", parts: :infinity)}
      MapSet.member?(allowed, as) -> {:ok, fp}
      MapSet.member?(allowed, List.first(fp)) and length(fp) == 1 -> {:ok, fp}
      true -> handle_unknown_field(fp, opts)
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

  defp handle_unknown_field(path, %{unknown_field: :warn}),
    do: {:ignore, %{type: :unknown_field, path: Enum.join(List.wrap(path), ".")}}

  defp handle_unknown_field(_path, _), do: :ignore

  defp cast_value({:array, inner}, :contains_all, list) when is_list(list),
    do: cast_list(inner, list)

  defp cast_value(type, :contains_all, list) when is_list(list),
    do: cast_list(type, list)

  defp cast_value(type, :in, list) when is_list(list), do: cast_list(type, list)
  defp cast_value(type, :nin, list) when is_list(list), do: cast_list(type, list)

  defp cast_value(_type, op, v) when op in [:starts_with, :ends_with] and is_binary(v),
    do: {:ok, v}

  defp cast_value(type, op, v), do: cast_value_with_dateonly(type, op, v)

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

      fun when is_function(fun, 1) ->
        fun.(term)

      nil ->
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
