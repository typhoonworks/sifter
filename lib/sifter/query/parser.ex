defmodule Sifter.Query.Parser do
  @moduledoc """
  The Parser transforms tokens from `Sifter.Query.Lexer` into structured `Sifter.AST` nodes.

  This parser implements a recursive descent parser with operator precedence parsing (Pratt parsing)
  to handle complex boolean expressions, field predicates, and set operations in the Sifter query language.

  ## Features

  - **Operator precedence**: Handles correct precedence with `AND` (precedence 20) binding tighter than `OR` (precedence 10)
  - **Boolean logic**: Supports `AND`, `OR`, and `NOT` operators with proper associativity
  - **Field predicates**: Parses field-based comparisons with various operators (`:`, `<`, `<=`, `>`, `>=`)
  - **Set operations**: Handles `IN` and `NOT IN` operations with list validation
  - **Wildcard support**: Processes prefix/suffix wildcards (`field:prefix*`, `field:*suffix`) for equality operations
  - **Grouping**: Supports parentheses for explicit precedence control
  - **Full-text search**: Handles bare terms as full-text search expressions

  ## Parser Architecture

  The parser uses a two-phase approach:
  1. **Prefix parsing**: Handles terms that can appear at the start of expressions (NOT, parentheses, field predicates, bare terms)
  2. **Infix parsing**: Manages binary operators (AND, OR) with precedence climbing

  ## Precedence Rules

  From highest to lowest precedence:
  1. `NOT` prefix operator (binds to the immediately following term)
  2. `AND` connector (precedence 20, left-associative)
  3. `OR` connector (precedence 10, left-associative)

  ## Wildcard Processing

  For equality operations (`:` operator), the parser automatically converts wildcard patterns:

  - `field:prefix*` → `%AST.Cmp{op: :starts_with, value: "prefix"}`
  - `field:*suffix` → `%AST.Cmp{op: :ends_with, value: "suffix"}`
  - `field:"*literal*"` → `%AST.Cmp{op: :eq, value: "*literal*"}` (quoted wildcards are literals)

  Wildcards are **not allowed** in:
  - Relational comparisons (`<`, `<=`, `>`, `>=`)
  - Set operations (`IN`, `NOT IN`) unless quoted

  ## Error Handling

  The parser provides detailed error reporting with the following error types:

  - `:unrecognized_token` - Invalid token in context (e.g., starting with connector)
  - `:unexpected_eof_after_operator` - Missing right-hand side after operator
  - `:missing_rhs` - Missing value after comparison operator
  - `:invalid_wildcard_position` - Wildcard in invalid position (e.g., middle of term)
  - `:wildcard_not_allowed_for_relop` - Wildcard used with relational operator
  - `:empty_list` - Empty parentheses where list expected
  - `:trailing_comma_in_list` - Trailing comma in list
  - `:missing_comma_in_list` - Missing comma between list items

  ## Notes

  The parser is designed to be used after tokenization by `Sifter.Query.Lexer` and produces
  AST nodes that can be consumed by a database query builder or further transformation passes.
  """

  alias Sifter.AST

  @compile {:inline,
            [
              peek: 1,
              advance: 1,
              connector?: 1,
              comparator?: 1,
              quoted_lexeme?: 1,
              wildcard_in?: 1,
              and_join: 2,
              or_join: 2
            ]}

  @prec %{
    AND_CONNECTOR: 20,
    OR_CONNECTOR: 10
  }

  @cmp_map %{
    EQUALITY_COMPARATOR: :eq,
    LESS_THAN_COMPARATOR: :lt,
    LESS_THAN_OR_EQUAL_TO_COMPARATOR: :lte,
    GREATER_THAN_COMPARATOR: :gt,
    GREATER_THAN_OR_EQUAL_TO_COMPARATOR: :gte
  }

  @cmp_types [
    :EQUALITY_COMPARATOR,
    :LESS_THAN_COMPARATOR,
    :LESS_THAN_OR_EQUAL_TO_COMPARATOR,
    :GREATER_THAN_COMPARATOR,
    :GREATER_THAN_OR_EQUAL_TO_COMPARATOR
  ]

  @type token :: {atom(), binary(), any(), {non_neg_integer(), non_neg_integer()}}

  defmodule State do
    @moduledoc """
    Internal parser state for tracking position during token stream processing.

    This module maintains the parser's position within the token stream and provides
    efficient random access to tokens using a tuple-based representation.

    ## Fields

    - `toks` - Tuple containing all tokens for O(1) access by index
    - `i` - Current position index in the token stream
    - `len` - Total number of tokens in the stream

    Used internally by the parser's recursive descent functions.
    """
    @enforce_keys [:toks, :i, :len]
    defstruct toks: {}, i: 0, len: 0

    @typedoc """
    Parser state for tracking position in token stream.

    - `toks`: All tokens as a tuple for efficient indexing
    - `i`: Current token index (0-based)
    - `len`: Total number of tokens
    """
    @type t :: %__MODULE__{
            toks: tuple(),
            i: non_neg_integer(),
            len: non_neg_integer()
          }
  end

  @doc """
  Parses a list of tokens from `Sifter.Query.Lexer` into a `Sifter.AST` tree.

  This is the main entry point for the parser. It takes a list of tokens produced by
  the lexer and transforms them into a structured AST that represents the query's
  logical structure.

  ## Parameters

  - `tokens` - A list of 4-tuples `{type, lexeme, literal, location}` produced by `Sifter.Query.Lexer.tokenize/1`

  ## Return Values

  - `{:ok, ast}` - Successfully parsed AST node
  - `{:error, {error_type, token}}` - Parse error with the problematic token
  """
  @spec parse([token]) :: {:ok, AST.t()} | {:error, {atom(), token()}}
  def parse([{:EOF, _, _, _}]), do: {:ok, %AST.And{children: []}}

  def parse(tokens) when is_list(tokens) do
    tup = List.to_tuple(tokens)
    st = %State{toks: tup, i: 0, len: tuple_size(tup)}

    case peek(st) do
      {type, _, _, _} = tok when type in [:AND_CONNECTOR, :OR_CONNECTOR] ->
        {:error, {:unrecognized_token, tok}}

      _ ->
        with {:ok, {expr, st1}} <- parse_expr(st, 0) do
          case peek(st1) do
            {:EOF, _, _, _} ->
              {:ok, expr}

            {type, _, _, _} = tok when type in [:AND_CONNECTOR, :OR_CONNECTOR] ->
              {:error, {:unexpected_eof_after_operator, tok}}

            tok ->
              {:error, {:expected, :EOF, tok}}
          end
        else
          {:error, _} = err -> err
        end
    end
  end

  @spec parse_expr(State.t(), non_neg_integer()) ::
          {:ok, {AST.t(), State.t()}} | {:error, {atom(), token()}} | :error
  defp parse_expr(st, min_prec) do
    with {:ok, {left, st1}} <- parse_prefix(st) do
      parse_infix_loop(left, st1, min_prec)
    end
  end

  defp parse_infix_loop(left, st, min_prec) do
    tok = peek(st)

    if connector?(tok) do
      prec = Map.get(@prec, elem(tok, 0), 0)
      if prec < min_prec, do: {:ok, {left, st}}, else: bind_infix(left, st, tok, prec, min_prec)
    else
      case tok do
        {:COMMA, _, _, _} = comma ->
          st1 = advance(st)

          case peek(st1) do
            {:RIGHT_PAREN, _, _, _} -> {:error, {:trailing_comma_in_list, comma}}
            _ -> {:error, {:stray_comma, comma}}
          end

        _ ->
          {:ok, {left, st}}
      end
    end
  end

  defp bind_infix(left, st, tok, prec, min_prec) do
    st2 = advance(st)
    tok2 = peek(st2)

    cond do
      connector?(tok2) ->
        {:error, {:unrecognized_token, tok2}}

      match?({:EOF, _, _, _}, tok2) ->
        {:error, {:unexpected_eof_after_operator, tok}}

      match?({:RIGHT_PAREN, _, _, _}, tok2) ->
        {:error, {:operator_before_right_paren, tok}}

      true ->
        with {:ok, {right, st3}} <- parse_expr(st2, prec + 1) do
          node =
            case elem(tok, 0) do
              :AND_CONNECTOR -> and_join(left, right)
              :OR_CONNECTOR -> or_join(left, right)
            end

          parse_infix_loop(node, st3, min_prec)
        end
    end
  end

  @spec parse_prefix(State.t()) ::
          {:ok, {AST.t(), State.t()}} | {:error, {atom(), token()}} | :error
  defp parse_prefix(st) do
    case peek(st) do
      {:LEFT_PAREN, _, _, _} = lparen ->
        st1 = advance(st)

        case peek(st1) do
          {:RIGHT_PAREN, _, _, _} ->
            {:error, {:empty_group, lparen}}

          _ ->
            case parse_expr(st1, 0) do
              {:ok, {expr, st2}} ->
                case peek(st2) do
                  {:RIGHT_PAREN, _, _, _} ->
                    st3 = advance(st2)
                    {:ok, {expr, st3}}

                  {:EOF, _, _, _} ->
                    {:error, {:missing_right_paren, lparen}}

                  {:COMMA, _, _, _} ->
                    {:error, {:unexpected_token, lparen}}

                  {type, _, _, _} = tok when type in [:AND_CONNECTOR, :OR_CONNECTOR] ->
                    {:error, {:operator_before_right_paren, tok}}

                  {:STRING_VALUE, _, _, _} = tok ->
                    {:error, {:missing_comma_in_list, tok}}

                  other ->
                    {:error, {:expected, :RIGHT_PAREN, other}}
                end

              {:error, {:stray_comma, _}} ->
                {:error, {:unexpected_token, lparen}}

              {:error, err} ->
                case err do
                  {:operator_before_right_paren, _} -> {:error, err}
                  {:trailing_comma_in_list, _} -> {:error, err}
                  _ -> {:error, {:unexpected_token, lparen}}
                end
            end
        end

      {:NOT_MODIFIER, _, _, _} = not_tok ->
        st1 = advance(st)

        case peek(st1) do
          {:EOF, _, _, _} ->
            {:error, {:not_without_term, not_tok}}

          _ ->
            with {:ok, {expr, st2}} <- parse_prefix(st1) do
              {:ok, {%AST.Not{expr: expr}, st2}}
            end
        end

      {:FIELD_IDENTIFIER, _, field_lit, _} ->
        parse_predicate(st, field_lit)

      {:STRING_VALUE, _lex, lit, _} ->
        st1 = advance(st)
        {:ok, {%AST.FullText{term: lit}, st1}}

      other ->
        {:error, {:unexpected_token, other}}
    end
  end

  defp parse_predicate(st, field_lit) do
    st1 = advance(st)

    cmp = peek(st1)

    if comparator?(cmp) do
      op = Map.fetch!(@cmp_map, elem(cmp, 0))
      st2 = advance(st1)

      case peek(st2) do
        {:LEFT_PAREN, _, _, _} = lparen when op == :eq ->
          {:error, {:list_not_allowed_for_colon_op, lparen}}

        vtok = {:STRING_VALUE, vlex, _vlit, _} ->
          if op != :eq and wildcard_in?(vlex) and not quoted_lexeme?(vlex) do
            {:error, {:wildcard_not_allowed_for_relop, vtok}}
          else
            case classify_colon_value(vtok, op == :eq) do
              {:error, _} = err ->
                err

              {override_op, value} ->
                path = split_field(field_lit)
                st3 = advance(st2)
                {:ok, {%AST.Cmp{field_path: path, op: override_op || op, value: value}, st3}}
            end
          end

        {:EOF, _, _, _} ->
          {:error, {:missing_rhs, cmp}}

        other ->
          {:error, {:expected_value, other}}
      end
    else
      case cmp do
        {:SET_IN, _, _, _} = set -> parse_set_list(st1, field_lit, set, :in)
        {:SET_NOT_IN, _, _, _} = set -> parse_set_list(st1, field_lit, set, :nin)
        other -> {:error, {:unexpected_token, other}}
      end
    end
  end

  defp parse_set_list(st_after_field, field_lit, set_tok, op) do
    st2 = advance(st_after_field)

    case peek(st2) do
      {:LEFT_PAREN, _, _, _} ->
        with {:ok, {items, st3}} <- parse_list(st2),
             :ok <- validate_list_items!(items) do
          values = Enum.map(items, fn {_lex, val} -> val end)
          {:ok, {%AST.Cmp{field_path: split_field(field_lit), op: op, value: values}, st3}}
        end

      _ ->
        {:error, {:expected_list_after_set_operator, set_tok}}
    end
  end

  defp parse_list(st) do
    case peek(st) do
      lparen = {:LEFT_PAREN, _, _, _} ->
        st1 = advance(st)

        case peek(st1) do
          {:RIGHT_PAREN, _, _, _} ->
            {:error, {:empty_list, lparen}}

          _ ->
            with {:ok, {first, st2}} <- parse_list_item(st1) do
              collect_list_items([first], st2)
            end
        end

      other ->
        {:error, {:expected, :LEFT_PAREN, other}}
    end
  end

  defp collect_list_items(acc, st) do
    case peek(st) do
      {:COMMA, _, _, _} = comma ->
        st1 = advance(st)
        # Check for trailing comma
        case peek(st1) do
          {:RIGHT_PAREN, _, _, _} ->
            {:error, {:trailing_comma_in_list, comma}}

          _ ->
            with {:ok, {item, st2}} <- parse_list_item(st1) do
              collect_list_items([item | acc], st2)
            end
        end

      {:RIGHT_PAREN, _, _, _} ->
        st1 = advance(st)
        {:ok, {Enum.reverse(acc), st1}}

      {:STRING_VALUE, _, _, _} = tok ->
        {:error, {:missing_comma_in_list, tok}}

      other ->
        {:error, {:unexpected_token_in_list, other}}
    end
  end

  defp parse_list_item(st) do
    case peek(st) do
      tok = {:STRING_VALUE, vlex, vlit, _} ->
        if not quoted_lexeme?(vlex) and wildcard_in?(vlex) do
          {:error, {:wildcard_not_allowed_in_list, tok}}
        else
          {:ok, {{vlex, vlit}, advance(st)}}
        end

      other ->
        {:error, {:expected_string_in_list, other}}
    end
  end

  defp validate_list_items!(items) do
    valid? =
      Enum.all?(items, fn {lex, _val} ->
        quoted_lexeme?(lex) or not wildcard_in?(lex)
      end)

    if valid?, do: :ok, else: :error
  end

  defp and_join(%AST.And{children: a}, %AST.And{children: b}), do: %AST.And{children: a ++ b}
  defp and_join(%AST.And{children: a}, %AST.Or{} = right), do: %AST.And{children: a ++ [right]}
  defp and_join(%AST.And{children: a}, right), do: %AST.And{children: a ++ [right]}
  defp and_join(left, %AST.And{children: b}), do: %AST.And{children: [left | b]}
  defp and_join(left, right), do: %AST.And{children: [left, right]}

  defp or_join(%AST.Or{children: a}, %AST.Or{children: b}), do: %AST.Or{children: a ++ b}
  defp or_join(%AST.Or{children: a}, right), do: %AST.Or{children: a ++ [right]}
  defp or_join(left, %AST.Or{children: b}), do: %AST.Or{children: [left | b]}
  defp or_join(left, right), do: %AST.Or{children: [left, right]}

  defp split_field(field_lit) when is_binary(field_lit),
    do: String.split(field_lit, ".", parts: :infinity)

  defp classify_colon_value(vtok = {:STRING_VALUE, vlex, vlit, _loc}, allow_wildcard?) do
    cond do
      quoted_lexeme?(vlex) or not allow_wildcard? ->
        {nil, vlit}

      String.starts_with?(vlex, "*") ->
        rest = String.slice(vlex, 1..-1//1)

        if wildcard_in?(rest),
          do: {:error, {:invalid_wildcard_position, vtok}},
          else: {:ends_with, rest}

      String.ends_with?(vlex, "*") ->
        base = String.trim_trailing(vlex, "*")

        if wildcard_in?(base),
          do: {:error, {:invalid_wildcard_position, vtok}},
          else: {:starts_with, base}

      wildcard_in?(vlex) ->
        {:error, {:invalid_wildcard_position, vtok}}

      true ->
        {nil, vlit}
    end
  end

  defp peek(%State{toks: toks, i: i, len: len}) when i < len do
    elem(toks, i)
  end

  defp peek(%State{i: i}) do
    {:EOF, "", nil, {i, 0}}
  end

  defp advance(%State{i: i} = st), do: %{st | i: i + 1}

  defp connector?({type, _, _, _}), do: type in [:AND_CONNECTOR, :OR_CONNECTOR]
  defp comparator?({type, _, _, _}), do: type in @cmp_types
  defp quoted_lexeme?(lex), do: String.starts_with?(lex, ["'", "\""])
  defp wildcard_in?(lex), do: String.contains?(lex, "*")
end
