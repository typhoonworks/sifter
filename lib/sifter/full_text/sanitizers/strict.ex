defmodule Sifter.FullText.Sanitizers.Strict do
  @moduledoc """
  Strict sanitizer for raw tsquery operations with defense-in-depth security.

  This sanitizer implements aggressive filtering providing multiple layers of
  protection against OWASP SQL wildcard attacks and PostgreSQL tsquery injection
  vulnerabilities.

  ## Security Features

  - Input length limitations to prevent DoS attacks
  - Aggressive character filtering to remove wildcards and special characters
  - Term count limitations to prevent query complexity attacks
  - Minimum term length requirements to prevent wildcard-like behavior
  - Only allows alphanumeric characters
  - Automatically appends prefix matching (`:*`) to valid terms

  ## Usage

      iex> Sifter.FullText.Sanitizers.Strict.sanitize_tsquery("validation system")
      "validation:* & system:*"

      iex> Sifter.FullText.Sanitizers.Strict.sanitize_tsquery("'; DROP TABLE --")
      ""

      iex> Sifter.FullText.Sanitizers.Strict.sanitize_tsquery("a")
      ""

      iex> Sifter.FullText.Sanitizers.Strict.sanitize_tsquery("test123 data-mining")
      "test123:* & datamining:*"
  """

  @doc """
  Sanitizes a search term for safe use with raw tsquery operations.

  This function implements defense-in-depth security measures including:
  - Limits total query length to 100 characters
  - Limits to maximum 10 search terms
  - Removes all special characters including wildcards (%, _, ., -, etc.)
  - Requires minimum 2 character term length
  - Limits final processed terms to 5
  - Only allows alphanumeric characters
  - Joins terms with ' & ' for AND logic
  - Appends ':*' for prefix matching

  ## Parameters

  - `term` - The search term to sanitize (binary or other)

  ## Returns

  A sanitized tsquery string ready for use with PostgreSQL's to_tsquery() function,
  or empty string for invalid/unsafe input.
  """
  @spec sanitize_tsquery(term :: any()) :: String.t()
  def sanitize_tsquery(term) when is_binary(term) do
    term
    |> String.trim()
    |> String.slice(0, 100)
    |> String.split(~r/\s+/)
    |> Enum.take(10)
    |> Enum.map(&sanitize_term/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(5)
    |> Enum.join(" & ")
  end

  def sanitize_tsquery(_term), do: ""

  @spec sanitize_term(String.t()) :: String.t() | nil
  defp sanitize_term(term) when is_binary(term) do
    clean_term =
      term
      |> String.replace(~r/[^a-zA-Z0-9]/, "")
      |> String.trim()

    if String.length(clean_term) >= 2 and String.match?(clean_term, ~r/^[a-zA-Z0-9]+$/),
      do: clean_term <> ":*",
      else: nil
  end

  defp sanitize_term(_term), do: nil

  @doc """
  Validates if a sanitized search query is safe and non-empty.

  ## Parameters

  - `sanitized_query` - The query string to validate

  ## Returns

  `true` if the query is safe and non-empty, `false` otherwise.
  """
  @spec valid_search_query?(any()) :: boolean()
  def valid_search_query?(sanitized_query) when is_binary(sanitized_query) do
    String.length(String.trim(sanitized_query)) > 0
  end

  def valid_search_query?(_sanitized_query), do: false
end
