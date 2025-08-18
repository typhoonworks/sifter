defmodule Sifter.Error do
  @moduledoc """
  Error handling for Sifter query parsing and execution.
  """

  defexception [:stage, :reason, :token]

  @type t :: %__MODULE__{
          stage: :lex | :parse | :build,
          reason: term(),
          token: term()
        }

  def message(%__MODULE__{stage: stage, reason: reason}) do
    case {stage, reason} do
      {:lex, {:unterminated_string, _, {offset, _}}} ->
        "Unterminated string at position #{offset}. Strings must be closed with a matching quote."

      {:lex, {:invalid_comparator, op, {offset, _}}} ->
        "Invalid operator '#{op}' at position #{offset}. Use ':' for equality or '>', '<', '>=', '<=' for comparisons."

      {:lex, {:unexpected_char, char, {offset, _}}} ->
        "Unexpected character '#{char}' at position #{offset}."

      {:lex, {:invalid_field, text, {offset, _}}} ->
        "Invalid field name '#{text}' at position #{offset}. Field names must start with a letter or underscore."

      {:parse, {:unexpected_token, {_type, lexeme, _literal, {offset, _}}}} ->
        "Unexpected token '#{lexeme}' at position #{offset}."

      {:parse, {:unexpected_eof_after_operator, {_type, lexeme, _literal, {offset, _length}}}} ->
        "Expected expression after '#{lexeme}' at position #{offset}. Operators must be followed by a value or field."

      {:parse, {:missing_right_paren, {_type, _lexeme, _literal, {offset, _}}}} ->
        "Missing closing parenthesis ')' for opening parenthesis at position #{offset}."

      {:parse, {:empty_list, {_type, _lexeme, _literal, {offset, _}}}} ->
        "Empty list at position #{offset}. Lists must contain at least one value."

      {:parse, {:trailing_comma_in_list, {_type, _lexeme, _literal, {offset, _}}}} ->
        "Trailing comma at position #{offset}. Remove the comma after the last list item."

      {:parse, {:invalid_wildcard_position, {_type, lexeme, _literal, {offset, _}}}} ->
        "Invalid wildcard pattern '#{lexeme}' at position #{offset}. Use 'field:prefix*' or 'field:*suffix', not middle wildcards."

      {:parse, {:empty_group, {_type, _lexeme, _literal, {offset, _}}}} ->
        "Empty parentheses at position #{offset}. Parentheses must contain an expression."

      # Builder errors (preserve existing behavior for now)
      {:build, {:error, inner_reason}} ->
        case inner_reason do
          {error_type, {_type, lexeme, _literal, {offset, _}}} ->
            format_parser_error(error_type, lexeme, offset)

          _ ->
            "Query build error: #{inspect(inner_reason)}"
        end

      {stage, reason} ->
        "Sifter #{stage} error: #{inspect(reason)}"
    end
  end

  defp format_parser_error(:unexpected_token, lexeme, offset) do
    "Unexpected token '#{lexeme}' at position #{offset}."
  end

  defp format_parser_error(:invalid_wildcard_position, lexeme, offset) do
    "Invalid wildcard pattern '#{lexeme}' at position #{offset}. Use 'field:prefix*' or 'field:*suffix', not middle wildcards."
  end

  defp format_parser_error(:empty_list, _lexeme, offset) do
    "Empty list at position #{offset}. Lists must contain at least one value."
  end

  defp format_parser_error(:trailing_comma_in_list, _lexeme, offset) do
    "Trailing comma at position #{offset}. Remove the comma after the last list item."
  end

  defp format_parser_error(:unexpected_eof_after_operator, lexeme, offset) do
    "Expected expression after '#{lexeme}' at position #{offset}. Operators must be followed by a value or field."
  end

  defp format_parser_error(:missing_right_paren, _lexeme, offset) do
    "Missing closing parenthesis ')' for opening parenthesis at position #{offset}."
  end

  defp format_parser_error(error_type, lexeme, offset) do
    "Parse error '#{error_type}' with token '#{lexeme}' at position #{offset}."
  end
end
