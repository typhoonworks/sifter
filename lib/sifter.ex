defmodule Sifter do
  @moduledoc """
  Sifter is a query filtering library for Elixir that converts search syntax from
  frontend applications into Ecto queries with full-text search support.

  ## Overview

  Sifter enables frontend JavaScript clients to build flexible queries that can be
  sent as simple strings to your backend API. It automatically handles field validation,
  type casting, association joins, and PostgreSQL full-text search while providing
  security through field allow-lists.

  ## Basic Usage

      # Simple field filtering
      {query, meta} = Sifter.filter!(Post, "status:published priority>3",
        schema: Post,
        allowed_fields: ["status", "priority"]
      )

      # With full-text search
      {query, meta} = Sifter.filter!(Post, "machine learning status:published",
        schema: Post,
        allowed_fields: ["status"],
        search_fields: ["title", "content"],        # Full-text search fields
        search_strategy: {:tsquery, "english"}      # Full-text search strategy
      )

      posts = Repo.all(query)

  ## Query Syntax

  Sifter supports a rich query syntax:

  - **Field predicates**: `status:published`, `priority>5`, `createdAt<='2024-01-01'`
  - **Boolean logic**: `status:draft OR status:review`, `published AND priority>3`
  - **Lists**: `status IN (draft, published)`, `tag NOT IN (spam, test)`, `labels ALL (urgent, backend)`
  - **Wildcards**: `title:data*`, `email:*@example.com`
  - **Full-text search**: Any unqualified terms search configured text fields

  ## Configuration

  The main configuration options:

  - `:schema` - The Ecto schema module (required if not inferrable from query)
  - `:allowed_fields` - Field allow-list with optional aliases
  - `:search_fields` - Fields to full-text search for unqualified terms
  - `:search_strategy` - How to perform full-text search (`:ilike`, `{:tsquery, "config"}`, etc.)
  - `:unknown_field` - How to handle unknown fields (`:ignore`, `:warn`, `:error`)

  ## Result Metadata

  Every query returns metadata about the filtering operation:

      meta = %{
        uses_full_text?: true,           # Whether full-text search was used
        added_select_fields: [:search_rank],  # Fields added to SELECT
        recommended_order: [search_rank: :desc],  # Suggested ordering
        warnings: []                      # Any warnings generated
      }
  """

  alias Sifter.Query.{Lexer, Parser}
  alias Sifter.Ecto.Builder
  alias Sifter.Error

  @type opts :: [
          schema: module(),
          allowed_fields: [String.t() | %{as: String.t(), field: String.t()}],
          # Fields for full-text search
          search_fields: :column | [String.t()],
          # Full-text search strategy
          search_strategy: :ilike | {:tsquery, String.t()}
        ]

  @type meta :: %{
          uses_full_text?: boolean(),
          added_select_fields: [atom()],
          recommended_order: [{atom(), :asc | :desc}] | nil
        }

  @spec filter(Ecto.Queryable.t(), String.t(), opts) ::
          {:ok, Ecto.Query.t(), meta()} | {:error, Error.t()}
  def filter(queryable, query, opts \\ []) when is_binary(query) do
    query = String.trim(query)

    with {:ok, tokens} <- tokenize(query),
         {:ok, ast} <- parse(tokens),
         {:ok, query2, meta} <- build(queryable, ast, opts) do
      {:ok, query2, meta}
    end
  end

  @spec filter!(Ecto.Queryable.t(), String.t(), opts) :: {Ecto.Query.t(), meta()}
  def filter!(queryable, query, opts \\ []) do
    case filter(queryable, query, opts) do
      {:ok, q, m} -> {q, m}
      {:error, e} -> raise e
    end
  end

  @spec to_sql(Ecto.Queryable.t(), String.t(), module(), opts) ::
          {:ok, String.t(), [term()], meta()} | {:error, Error.t()}
  def to_sql(queryable, query, adapter, opts \\ []) when is_binary(query) do
    query = String.trim(query)

    case filter(queryable, query, opts) do
      {:ok, ecto_query, meta} ->
        {sql, params} = Ecto.Adapters.SQL.to_sql(:all, adapter, ecto_query)
        {:ok, sql, params, meta}

      {:error, error} ->
        {:error, error}
    end
  end

  @spec to_sql!(Ecto.Queryable.t(), String.t(), module(), opts) :: {String.t(), [term()], meta()}
  def to_sql!(queryable, query, adapter, opts \\ []) do
    case to_sql(queryable, query, adapter, opts) do
      {:ok, sql, params, meta} -> {sql, params, meta}
      {:error, error} -> raise error
    end
  end

  defp tokenize(query) do
    case Lexer.tokenize(query) do
      {:ok, tokens} -> {:ok, tokens}
      {:error, reason} -> {:error, %Error{stage: :lex, reason: reason}}
    end
  end

  defp parse(tokens) do
    case Parser.parse(tokens) do
      {:ok, ast} -> {:ok, ast}
      {:error, {type, token}} -> {:error, %Error{stage: :parse, reason: {type, token}}}
    end
  end

  defp build(queryable, ast, opts) do
    case Builder.apply(queryable, ast, opts) do
      {:ok, query, meta} -> {:ok, query, meta}
      {:error, reason} -> {:error, %Error{stage: :build, reason: reason}}
    end
  end
end
