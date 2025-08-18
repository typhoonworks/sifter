defmodule Sifter.FullText.Sanitizers.Basic do
  @moduledoc """
  Basic sanitizer for plainto_tsquery operations.

  This sanitizer provides minimal, safe transformations suitable for use with
  PostgreSQL's `plainto_tsquery` function, which automatically handles most
  special characters and provides inherent protection against injection.

  ## Security Features

  - Trims whitespace
  - Limits input length to prevent DoS attacks  
  - Collapses multiple whitespace characters
  - Returns empty string for nil/invalid input

  ## Usage

      iex> Sifter.FullText.Sanitizers.Basic.sanitize_plainto("search term")
      "search term"

      iex> Sifter.FullText.Sanitizers.Basic.sanitize_plainto("  multiple   spaces  ")
      "multiple spaces"

      iex> Sifter.FullText.Sanitizers.Basic.sanitize_plainto(nil)
      ""
  """

  @doc """
  Sanitizes a search term for safe use with plainto_tsquery.

  This function performs minimal sanitization since plainto_tsquery provides
  built-in protection against most injection attacks by automatically escaping
  special characters and treating input as plain text.

  ## Parameters

  - `term` - The search term to sanitize (binary or other)

  ## Returns

  A sanitized string suitable for plainto_tsquery, or empty string for invalid input.
  """
  @spec sanitize_plainto(term :: any()) :: String.t()
  def sanitize_plainto(term) when is_binary(term) do
    term
    |> String.trim()
    |> String.slice(0, 100)
    |> String.replace(~r/\s+/, " ")
  end

  def sanitize_plainto(_term), do: ""
end
