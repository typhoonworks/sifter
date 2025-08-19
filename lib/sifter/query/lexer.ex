defmodule Sifter.Query.Lexer do
  @moduledoc """
  A lexical analyzer for the Sifter query language that tokenizes search queries.

  Sifter provides a query language for filtering data with support for:
  - Field-based predicates with various operators (`field:value`, `field>10`)
  - Set operations (`field IN (value1, value2)`)
  - Boolean logic with `AND`, `OR`, and `NOT` operators
  - Quoted strings and bare text search
  - Wildcard prefix/suffix matching (`field:prefix*`, `field:*suffix`)

  ## Grammar

  ```ebnf
  Query         = [ whitespace ] , [ Term , { ( whitespace , Connective , whitespace | whitespace ) , Term } ] , [ whitespace ] ;

  Connective    = "AND" | "OR" ;           (* AND has higher precedence than OR *)

  Term          = [ Modifier ] , ( "(" , [ whitespace ] , Query , [ whitespace ] , ")" | Predicate | FullText ) ;

  Modifier      = "-" | "NOT" , whitespace ;          (* "-" has no following space *)

  Predicate     = Field , ( ColonOp , ValueOrList | SetOp , List ) ;

  ColonOp       = ":" | "<" | "<=" | ">" | ">=" ;

  SetOp         = whitespace , "IN" , whitespace | whitespace , "NOT" , whitespace , "IN" , whitespace | whitespace , "ALL" , whitespace ;

  Field         = Name , { "." , Name } ;      (* dot paths, e.g. tags.name, project.client.name *)

  ValueOrList   = List | Value ;
  List          = "(" , [ whitespace ] , Value , { [ whitespace ] , "," , [ whitespace ] , Value } , [ whitespace ] , ")" ;  (* non-empty *)

  (* STRICT wildcard rules - only for fielded values:
     field:value*  → starts_with match
     field:*value  → ends_with match
     Note: No middle wildcards like *value* - use FullText for contains-across-fields *)
  Value         = PrefixValue | SuffixValue | ScalarValue | NullValue ;
  PrefixValue   = ScalarNoStar , "*" ;                       (* starts_with *)
  SuffixValue   = "*" , ScalarNoStar ;                       (* ends_with *)
  ScalarValue   = Quoted | BareNoStar ;
  NullValue     = NULL

  (* Bare terms perform FullText search across configured fields *)
  FullText      = Quoted | Bare ;

  (* Lexical rules *)
  Name          = NameStart , { NameCont } ;
  NameStart     = ALNUM | "_" ;
  NameCont      = ALNUM | "_" | "-" ;                      (* allow hyphen inside names *)
  BareNoStar    = { Visible - Special - "*" }- ;          (* one or more visible chars excluding special and asterisk *)
  Bare          = { Visible - Special }- ;                 (* one or more visible chars excluding special *)
  Quoted        = "'" , { CharEsc | ? not "'" ? } , "'"
                | '"' , { CharEsc | ? not '"' ? } , '"' ;
  CharEsc       = "\\" , ? any character ? ;
  Special       = whitespace | "(" | ")" | ":" | "<" | ">" | "=" | "," ;
  whitespace    = { ? space | tab | carriage return | line feed ? }- ;  (* one or more whitespace chars *)
  Visible       = ? any visible character ? ;
  ALNUM         = "A" | "B" | "C" | "D" | "E" | "F" | "G" | "H" | "I" | "J" | "K" | "L" | "M" | "N" | "O" | "P" | "Q" | "R" | "S" | "T" | "U" | "V" | "W" | "X" | "Y" | "Z" | "a" | "b" | "c" | "d" | "e" | "f" | "g" | "h" | "i" | "j" | "k" | "l" | "m" | "n" | "o" | "p" | "q" | "r" | "s" | "t" | "u" | "v" | "w" | "x" | "y" | "z" | "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" ;
  ```

  ## Behavior Notes

  - **Implied AND**: Missing connectives between terms default to AND operation
  - **Case-sensitive keywords**: `AND`, `OR`, `NOT`, `IN`, `ALL`, `NULL` are case-sensitive (must be uppercase)
  - **Bare text search**: Unfielded terms perform "contains" search across configured fields
  - **Wildcard constraints**: Prefix/suffix wildcards (`*`) only work in fielded values
  - **Forward progress**: Every tokenization step consumes ≥1 byte or returns an error

  ## Token Types

  The lexer produces tokens with the following structure: `{type, lexeme, literal, location}`

  - `type`: Atom identifying the token type (`:STRING_VALUE`, `:FIELD_IDENTIFIER`, etc.)
  - `lexeme`: Original text from the source
  - `literal`: Processed/decoded value (e.g., unescaped strings)
  - `location`: `{byte_offset, byte_length}` tuple for source position
  """

  import Sifter.Utils, only: [to_snake_case: 1]

  @compile {:inline,
            [
              tok: 5,
              emit: 5,
              consume_ws: 3,
              scan_relop: 2,
              scan_set_operator: 3,
              check_no_space_after_operator: 4,
              at_term_boundary: 1
            ]}

  @type byte_offset :: non_neg_integer()
  @type byte_length :: non_neg_integer()

  @typedoc "Source location (byte-based): {byte_offset, byte_length}."
  @type loc :: {byte_offset, byte_length}

  @typedoc """
  Token: {type, lexeme, literal, loc}
  - type: atom tag
  - lexeme: exact substring
  - literal: unescaped/decoded value
  - loc: {offset_bytes, length_bytes}
  """
  @type token ::
          {:STRING_VALUE, binary(), binary(), loc}
          | {:FIELD_IDENTIFIER, binary(), binary(), loc}
          | {:EQUALITY_COMPARATOR, binary(), nil, loc}
          | {:LESS_THAN_COMPARATOR, binary(), nil, loc}
          | {:LESS_THAN_OR_EQUAL_TO_COMPARATOR, binary(), nil, loc}
          | {:GREATER_THAN_COMPARATOR, binary(), nil, loc}
          | {:GREATER_THAN_OR_EQUAL_TO_COMPARATOR, binary(), nil, loc}
          | {:SET_IN, binary(), atom(), loc}
          | {:SET_NOT_IN, binary(), atom(), loc}
          | {:SET_CONTAINS_ALL, binary(), atom(), loc}
          | {:AND_CONNECTOR, binary(), binary(), loc}
          | {:OR_CONNECTOR, binary(), binary(), loc}
          | {:LEFT_PAREN, binary(), nil, loc}
          | {:RIGHT_PAREN, binary(), nil, loc}
          | {:COMMA, binary(), nil, loc}
          | {:NOT_MODIFIER, binary(), nil, loc}
          | {:EOF, binary(), nil, loc}

  defguardp is_ws(c) when c in [?\s, ?\t, ?\r, ?\n]
  defguardp is_special(c) when c in [?(, ?), ?:, ?<, ?>, ?=, ?,, ?', ?"]
  defguardp is_alpha(c) when (c >= ?A and c <= ?Z) or (c >= ?a and c <= ?z)
  defguardp is_digit(c) when c >= ?0 and c <= ?9
  defguardp is_name_start(c) when is_alpha(c) or c == ?_
  defguardp is_name_cont(c) when is_alpha(c) or is_digit(c) or c == ?_ or c == ?-

  defmodule State do
    @moduledoc """
    Internal lexer state for tracking position during string scanning.

    This module maintains the lexer's position within the source string and accumulates
    tokens as they are recognized during the scanning process.

    ## Fields

    - `src` - Original complete source string
    - `rest` - Remaining unprocessed bytes
    - `off` - Current byte offset in the source
    - `len` - Total length of the source string
    - `acc` - Accumulated tokens (in reverse order)
    - `prev_term?` - Whether the previous token was a term (affects implied AND insertion)

    Used internally by the lexer's scanning functions.
    """
    @enforce_keys [:src, :rest, :off, :len, :acc, :prev_term?]
    defstruct src: "", rest: <<>>, off: 0, len: 0, acc: [], prev_term?: false

    @typedoc """
    Lexer state for tracking position during string scanning.

    - `src`: Original complete source string
    - `rest`: Remaining bytes to scan
    - `off`: Current byte offset in source
    - `len`: Total source length in bytes
    - `acc`: Accumulated tokens (reversed)
    - `prev_term?`: True after term tokens, false after structural tokens
    """
    @type t :: %__MODULE__{
            src: binary(),
            rest: binary(),
            off: non_neg_integer(),
            len: non_neg_integer(),
            acc: [Sifter.Query.Lexer.token()],
            prev_term?: boolean()
          }
  end

  @doc """
  Tokenizes a Sifter query string into a list of tokens for parsing.

  This is the main entry point for the lexer. It processes a query string and produces
  a list of tokens that can be consumed by `Sifter.Query.Parser`.

  ## Parameters

  - `src` - The query string to tokenize

  ## Return Values

  - `{:ok, tokens}` - Successfully tokenized list of tokens, always ending with `:EOF`
  - `{:error, reason}` - Tokenization error with details
  """
  @spec tokenize(String.t()) :: {:ok, [token]} | {:error, term()}
  def tokenize(src) when is_binary(src) do
    len = byte_size(src)

    %State{src: src, rest: src, off: 0, len: len, acc: [], prev_term?: false}
    |> scan()
    |> case do
      {:error, _} = error -> error
      %State{acc: acc, len: len} -> {:ok, Enum.reverse([tok(:EOF, "", nil, len, 0) | acc])}
    end
  end

  def tokenize(_), do: {:error, :invalid_input}

  defp scan(%State{rest: <<>>} = st), do: st

  defp scan(st) do
    with {:ok, st1} <- consume_ws_and_maybe_implied_and(st),
         {:ok, st2} <- scan_next(st1) do
      scan(st2)
    else
      {:done, st1} -> st1
      {:error, _} = err -> err
    end
  end

  defp consume_ws_and_maybe_implied_and(
         %State{rest: rest, off: off, src: src, acc: acc, prev_term?: prev?} = st
       ) do
    {off1, rest1, ws_len} = consume_ws(rest, off, 0)

    if rest1 == <<>> do
      {:done, %{st | rest: rest1, off: off1}}
    else
      acc1 =
        if ws_len > 0 and prev? and not explicit_connector_ahead?(rest1) and
             not structural_ahead?(rest1) do
          ws = binary_part(src, off1 - ws_len, ws_len)
          [tok(:AND_CONNECTOR, ws, "and", off1 - ws_len, ws_len) | acc]
        else
          acc
        end

      {:ok, %{st | rest: rest1, off: off1, acc: acc1}}
    end
  end

  defp explicit_connector_ahead?(<<c1, rest::binary>>) when is_name_start(c1) do
    case {c1, rest} do
      {?O, <<?R>>} ->
        true

      {?O, <<?R, c3, _::binary>>}
      when is_ws(c3) or c3 in [?), ?(, ?,] ->
        true

      {?A, <<?N, ?D>>} ->
        true

      {?A, <<?N, ?D, c4, _::binary>>}
      when is_ws(c4) or c4 in [?), ?(, ?,] ->
        true

      _ ->
        false
    end
  end

  defp explicit_connector_ahead?(_), do: false

  defp structural_ahead?(<<c, _::binary>>) when c in [?), ?,], do: true
  defp structural_ahead?(_), do: false

  defp scan_relop(<<?<, ?=, rest::binary>>, off),
    do: check_no_space_after_operator(rest, off + 2, "<=", 2)

  defp scan_relop(<<?<, rest::binary>>, off),
    do: check_no_space_after_operator(rest, off + 1, "<", 1)

  defp scan_relop(<<?>, ?=, rest::binary>>, off),
    do: check_no_space_after_operator(rest, off + 2, ">=", 2)

  defp scan_relop(<<?>, rest::binary>>, off),
    do: check_no_space_after_operator(rest, off + 1, ">", 1)

  defp scan_next(%State{rest: <<?', _::binary>>} = st), do: scan_quoted_string(st, ?')
  defp scan_next(%State{rest: <<?\", _::binary>>} = st), do: scan_quoted_string(st, ?\")

  defp scan_next(%State{rest: <<?=, _::binary>>, off: off}),
    do: {:error, {:invalid_comparator, "=", {off, 1}}}

  defp scan_next(%State{rest: <<?(, rest::binary>>} = st) do
    tok1 = tok(:LEFT_PAREN, "(", nil, st.off, 1)
    emit(st, tok1, rest, st.off + 1, false)
  end

  defp scan_next(%State{rest: <<?), rest::binary>>} = st) do
    tok1 = tok(:RIGHT_PAREN, ")", nil, st.off, 1)
    emit(st, tok1, rest, st.off + 1, true)
  end

  defp scan_next(%State{rest: <<?,, rest::binary>>} = st) do
    tok1 = tok(:COMMA, ",", nil, st.off, 1)
    emit(st, tok1, rest, st.off + 1, false)
  end

  defp scan_next(%State{rest: <<?-, rest::binary>>, prev_term?: false} = st) do
    tok1 = tok(:NOT_MODIFIER, "-", nil, st.off, 1)
    emit(st, tok1, rest, st.off + 1, false)
  end

  defp scan_next(%State{rest: <<c, _::binary>>, off: off})
       when c in [?:, ?<, ?>, ?=, ?', ?"] do
    {:error, {:unexpected_char, <<c>>, {off, 1}}}
  end

  defp scan_next(%State{rest: <<c, _::binary>>} = st) when is_name_start(c),
    do: scan_field_predicate_or_bare(st)

  defp scan_next(st), do: scan_bare_string(st)

  defp scan_quoted_string(%State{rest: rest, off: off, src: src} = st, quote) do
    case scan_quoted(rest, off, quote) do
      {:ok, off2, rest2, literal} ->
        len_lex = off2 - off
        lexeme = binary_part(src, off, len_lex)
        tok1 = tok(:STRING_VALUE, lexeme, literal, off, len_lex)
        emit(st, tok1, rest2, off2, true)

      {:error, :unterminated_string} ->
        consumed_len = byte_size(rest)
        {:error, {:unterminated_string, nil, {off, consumed_len}}}
    end
  end

  defp scan_field_predicate_or_bare(
         %State{rest: rest, off: off, src: src, acc: _acc, prev_term?: prev?} = st
       ) do
    case scan_field_path(rest, off) do
      {:error, _} = err ->
        err

      {field_end_off, rest_after_field} ->
        field_len = field_end_off - off
        lexeme = binary_part(src, off, field_len)

        case rest_after_field do
          <<c, _::binary>> when c in [?:, ?<, ?>, ?=] ->
            handle_field_or_bare_term(st, off, field_len, rest_after_field, field_end_off)

          _ when prev? ->
            case is_connector_at_boundary(lexeme, rest_after_field) do
              {:or, _len} ->
                tok1 = tok(:OR_CONNECTOR, lexeme, "or", off, field_len)
                emit(st, tok1, rest_after_field, field_end_off, false)

              {:and, _len} ->
                tok1 = tok(:AND_CONNECTOR, lexeme, "and", off, field_len)
                emit(st, tok1, rest_after_field, field_end_off, false)

              :none ->
                handle_field_or_bare_term(st, off, field_len, rest_after_field, field_end_off)
            end

          _ ->
            case is_not_modifier_at_boundary(lexeme, rest_after_field) do
              {:not, _len} ->
                tok1 = tok(:NOT_MODIFIER, lexeme, nil, off, field_len)
                emit(st, tok1, rest_after_field, field_end_off, false)

              :none ->
                handle_field_or_bare_term(st, off, field_len, rest_after_field, field_end_off)
            end
        end
    end
  end

  defp is_connector_at_boundary(<<?O, ?R>>, rest) do
    if at_term_boundary(rest), do: {:or, 2}, else: :none
  end

  defp is_connector_at_boundary(<<?A, ?N, ?D>>, rest) do
    if at_term_boundary(rest), do: {:and, 3}, else: :none
  end

  defp is_connector_at_boundary(_, _), do: :none

  defp is_not_modifier_at_boundary(<<?N, ?O, ?T>>, rest) do
    case rest do
      <<c, _::binary>> when is_ws(c) -> {:not, 3}
      _ -> :none
    end
  end

  defp is_not_modifier_at_boundary(_, _), do: :none

  defp at_term_boundary(<<>>), do: true
  defp at_term_boundary(<<c, _::binary>>) when is_ws(c) or c in [?), ?(, ?,], do: true
  defp at_term_boundary(_), do: false

  defp handle_field_or_bare_term(
         %State{rest: full_rest, off: full_off, src: src, acc: acc} = st,
         start_off,
         field_len,
         rest_after_field,
         field_end_off
       ) do
    case rest_after_field do
      <<?:, _rest_after_colon::binary>> ->
        field_tok = emit_field(st, start_off, field_len)

        case scan_colon_operator(rest_after_field, field_end_off) do
          {:ok, op_tok, rest_after_op, off_after_op} ->
            {:ok,
             %{
               st
               | rest: rest_after_op,
                 off: off_after_op,
                 acc: [op_tok, field_tok | acc],
                 prev_term?: false
             }}

          {:error, _} = err ->
            err
        end

      <<c, _::binary>> when c in [?<, ?>] ->
        scan_relop(rest_after_field, field_end_off)
        |> case do
          {:ok, op_tok, rest_after_op, off_after_op} ->
            emit_field_and_op(st, start_off, field_len, op_tok, rest_after_op, off_after_op)

          error ->
            error
        end

      <<?=, _::binary>> ->
        {:error, {:invalid_comparator, "=", {field_end_off, 1}}}

      <<c, ?:, _::binary>> when is_ws(c) ->
        {:error, {:invalid_predicate_spacing, nil, {field_end_off, 1}}}

      <<c, ?<, _::binary>> when is_ws(c) ->
        {:error, {:invalid_predicate_spacing, nil, {field_end_off, 1}}}

      <<c, ?>, _::binary>> when is_ws(c) ->
        {:error, {:invalid_predicate_spacing, nil, {field_end_off, 1}}}

      _ ->
        case scan_set_operator(rest_after_field, field_end_off, src) do
          {:in, in_off, rest_after_in} ->
            field_tok = emit_field(st, start_off, field_len)
            in_lexeme = binary_part(src, in_off, 2)
            in_tok = tok(:SET_IN, in_lexeme, :in, in_off, 2)

            {:ok,
             %{
               st
               | rest: rest_after_in,
                 off: in_off + 2,
                 acc: [in_tok, field_tok | acc],
                 prev_term?: false
             }}

          {:not_in, not_off, rest_after_not_in} ->
            field_tok = emit_field(st, start_off, field_len)
            not_in_lexeme = binary_part(src, not_off, 6)
            not_in_tok = tok(:SET_NOT_IN, not_in_lexeme, :not_in, not_off, 6)

            {:ok,
             %{
               st
               | rest: rest_after_not_in,
                 off: not_off + 6,
                 acc: [not_in_tok, field_tok | acc],
                 prev_term?: false
             }}

          {:contains_all, all_off, rest_after_all} ->
            field_tok = emit_field(st, start_off, field_len)
            all_lexeme = binary_part(src, all_off, 3)
            all_tok = tok(:SET_CONTAINS_ALL, all_lexeme, :contains_all, all_off, 3)

            {:ok,
             %{
               st
               | rest: rest_after_all,
                 off: all_off + 3,
                 acc: [all_tok, field_tok | acc],
                 prev_term?: false
             }}

          {:error, err} ->
            {:error, err}

          :none ->
            {value_end_off, rest_after_value} = scan_bare_literal(full_rest, full_off)
            value_len = value_end_off - full_off
            lexeme = binary_part(src, full_off, value_len)
            tok1 = tok(:STRING_VALUE, lexeme, lexeme, full_off, value_len)
            emit(st, tok1, rest_after_value, value_end_off, true)
        end
    end
  end

  defp scan_set_operator(rest, off, _src) do
    case consume_ws(rest, off, 0) do
      {_off1, <<>>, _ws_len} ->
        :none

      {_off1, _rest1, 0} ->
        :none

      {off1, rest1, ws_len} when ws_len > 0 ->
        case rest1 do
          <<?N, ?O, ?T, ws, ?I, ?N, rest2::binary>>
          when is_ws(ws) ->
            case rest2 do
              <<c6, _::binary>> when is_name_cont(c6) ->
                :none

              <<c6, _::binary>> when is_ws(c6) ->
                {:not_in, off1, rest2}

              _ ->
                {:error, {:invalid_predicate_spacing, nil, {off1 + 6, 1}}}
            end

          <<?A, ?L, ?L, rest2::binary>> ->
            case rest2 do
              <<c4, _::binary>> when is_name_cont(c4) ->
                :none

              <<c4, _::binary>> when is_ws(c4) ->
                {:contains_all, off1, rest2}

              _ ->
                {:error, {:invalid_predicate_spacing, nil, {off1 + 3, 1}}}
            end

          <<?I, ?N, rest2::binary>> ->
            case rest2 do
              <<c3, _::binary>> when is_name_cont(c3) ->
                :none

              <<c3, _::binary>> when is_ws(c3) ->
                {:in, off1, rest2}

              _ ->
                {:error, {:invalid_predicate_spacing, nil, {off1 + 2, 1}}}
            end

          _ ->
            :none
        end
    end
  end

  defp scan_bare_string(%State{rest: rest, off: off, src: src} = st) do
    {off2, rest2} = scan_bare_literal(rest, off)

    if off2 > off do
      len_lex = off2 - off
      lexeme = binary_part(src, off, len_lex)
      tok1 = tok(:STRING_VALUE, lexeme, lexeme, off, len_lex)
      emit(st, tok1, rest2, off2, true)
    else
      {:ok, st}
    end
  end

  defp consume_ws(<<c, rest::binary>>, off, n) when is_ws(c),
    do: consume_ws(rest, off + 1, n + 1)

  defp consume_ws(rest, off, n), do: {off, rest, n}

  defp scan_quoted(<<quote, rest::binary>>, start_off, quote) do
    scan_quoted_content(rest, start_off + 1, quote, [])
  end

  defp scan_quoted_content(<<>>, _off, _quote, _acc),
    do: {:error, :unterminated_string}

  defp scan_quoted_content(<<quote, rest::binary>>, off, quote, acc) do
    literal = acc |> Enum.reverse() |> :erlang.iolist_to_binary()
    {:ok, off + 1, rest, literal}
  end

  defp scan_quoted_content(<<?\\, c, rest::binary>>, off, quote, acc),
    do: scan_quoted_content(rest, off + 2, quote, [c | acc])

  defp scan_quoted_content(<<c, rest::binary>>, off, quote, acc),
    do: scan_quoted_content(rest, off + 1, quote, [c | acc])

  defp scan_bare_literal(rest, off), do: do_scan_bare_literal(rest, off)

  defp do_scan_bare_literal(<<>>, end_off), do: {end_off, <<>>}

  defp do_scan_bare_literal(<<c, rest::binary>>, end_off) when is_ws(c) or is_special(c),
    do: {end_off, <<c, rest::binary>>}

  defp do_scan_bare_literal(<<_c, rest::binary>>, end_off),
    do: do_scan_bare_literal(rest, end_off + 1)

  defp scan_field_path(<<c, rest::binary>>, start_off) when is_name_start(c) do
    do_scan_field_path(rest, start_off + 1)
  end

  defp scan_field_path(rest, off), do: {off, rest}

  defp do_scan_field_path(<<c, rest::binary>>, off) when is_name_cont(c) do
    do_scan_field_path(rest, off + 1)
  end

  defp do_scan_field_path(<<?., c, rest::binary>>, off) when is_name_start(c) do
    do_scan_field_path(<<c, rest::binary>>, off + 1)
  end

  defp do_scan_field_path(<<?., _rest::binary>>, off) do
    {:error, {:invalid_field, ".", {off, 1}}}
  end

  defp do_scan_field_path(rest, off) do
    {off, rest}
  end

  defp scan_colon_operator(<<?:, rest::binary>>, off) do
    case rest do
      <<?<, rest2::binary>> ->
        case rest2 do
          <<c, ?=, _::binary>> when is_ws(c) ->
            {:error, {:broken_operator, "< =", {off + 2, 2}}}

          <<?=, rest3::binary>> ->
            check_no_space_after_operator(rest3, off + 3, ":<=", 3)

          _ ->
            check_no_space_after_operator(rest2, off + 2, ":<", 2)
        end

      <<?>, rest2::binary>> ->
        case rest2 do
          <<c, ?=, _::binary>> when is_ws(c) ->
            {:error, {:broken_operator, "> =", {off + 2, 2}}}

          <<?=, rest3::binary>> ->
            check_no_space_after_operator(rest3, off + 3, ":>=", 3)

          _ ->
            check_no_space_after_operator(rest2, off + 2, ":>", 2)
        end

      _ ->
        check_no_space_after_operator(rest, off + 1, ":", 1)
    end
  end

  defp scan_colon_operator(_, off) do
    {:error, {:invalid_comparator, nil, {off, 0}}}
  end

  defp emit_field(st, off, len) do
    lex = binary_part(st.src, off, len)
    lit = to_snake_case(lex)
    tok(:FIELD_IDENTIFIER, lex, lit, off, len)
  end

  defp emit_field_and_op(st, field_off, field_len, op_tok, rest, off) do
    field_tok = emit_field(st, field_off, field_len)
    {:ok, %{st | rest: rest, off: off, acc: [op_tok, field_tok | st.acc], prev_term?: false}}
  end

  defp emit(%State{acc: acc} = st, token, rest, off, is_term?) do
    {:ok, %{st | rest: rest, off: off, acc: [token | acc], prev_term?: is_term?}}
  end

  defp tok(type, lexeme, literal, off, len), do: {type, lexeme, literal, {off, len}}

  defp check_no_space_after_operator(rest, op_end_off, op_lexeme, op_len) do
    case rest do
      <<c, _::binary>> when is_ws(c) ->
        {:error, {:invalid_predicate_spacing, nil, {op_end_off, 1}}}

      _ ->
        type =
          case op_lexeme do
            ":" -> :EQUALITY_COMPARATOR
            "<" -> :LESS_THAN_COMPARATOR
            "<=" -> :LESS_THAN_OR_EQUAL_TO_COMPARATOR
            ">" -> :GREATER_THAN_COMPARATOR
            ">=" -> :GREATER_THAN_OR_EQUAL_TO_COMPARATOR
          end

        tok1 = tok(type, op_lexeme, nil, op_end_off - op_len, op_len)
        {:ok, tok1, rest, op_end_off}
    end
  end
end
