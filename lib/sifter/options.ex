defmodule Sifter.Options do
  @moduledoc """
  Resolved, runtime options that control Sifter's behavior.

  Precedence (highest → lowest):
  1. Per-call overrides (opts to `Sifter.filter/3`)
  2. Per-process/request default (e.g., set by a Plug)
  3. Application config (`config :sifter, :options, ...`)

  ## Full-text Search Sanitization

  Sifter provides pluggable sanitization for full-text search terms with two built-in
  sanitizers and support for custom sanitization functions.

  ### Default Behavior

  - `:tsquery_mode` defaults to `:plainto` (uses `plainto_tsquery`)
  - When `:tsquery_mode` is `:plainto`, defaults to `Sifter.FullText.Sanitizers.Basic`
  - When `:tsquery_mode` is `:raw`, defaults to `Sifter.FullText.Sanitizers.Strict`

  ### Configuration Examples

      # Application-wide defaults
      config :sifter, :options,
        tsquery_mode: :raw,
        full_text_sanitizer: &MyApp.CustomSanitizer.sanitize/1

      # Per-call override
      Sifter.filter!(Entry, query,
        schema: Entry,
        search_fields: :searchable,
        search_strategy: {:column, {"english", :searchable}},
        tsquery_mode: :raw,
        full_text_sanitizer: {MyApp.Sanitizer, :custom_sanitize, []}
      )
  """

  @enforce_keys []
  # :ignore | :warn | :error
  defstruct unknown_field: :ignore,
            # :ignore | :warn | :error
            unknown_assoc: :ignore,
            # :warn | :error
            unsupported_op: :error,
            # :ignore | :warn | :error
            invalid_cast: :error,
            # non_neg_integer
            max_joins: 1,
            # :ignore | :error
            join_overflow: :error,
            # :false | :true | :error
            empty_in: false,
            # :plainto | :raw
            tsquery_mode: :plainto,
            # function | {module, function, args}
            full_text_sanitizer: nil

  @type t :: %__MODULE__{
          unknown_field: :ignore | :warn | :error,
          unknown_assoc: :ignore | :warn | :error,
          unsupported_op: :warn | :error,
          invalid_cast: :ignore | :warn | :error,
          max_joins: non_neg_integer(),
          join_overflow: :ignore | :error,
          empty_in: false | true | :error,
          tsquery_mode: :plainto | :raw,
          full_text_sanitizer: (String.t() -> String.t()) | {module(), atom(), list()} | nil
        }

  def mode(:lenient), do: %__MODULE__{}

  def mode(:strict),
    do: %__MODULE__{
      unknown_field: :error,
      unknown_assoc: :error,
      unsupported_op: :error,
      invalid_cast: :error
    }

  def from_keyword(kw) when is_list(kw), do: struct(__MODULE__, kw)
  def merge(%__MODULE__{} = base, kw) when is_list(kw), do: struct(base, kw)

  @doc """
  Resolve final options from app config, process default, and per-call overrides.

  Recognizes `:mode` (`:lenient | :strict`) and individual knobs.
  """
  def resolve(call_opts \\ []) do
    base =
      case Application.get_env(:sifter, :options) do
        nil -> mode(:lenient)
        :lenient -> mode(:lenient)
        :strict -> mode(:strict)
        kw when is_list(kw) -> from_keyword(kw)
        %__MODULE__{} = o -> o
      end

    base2 =
      case Process.get(:sifter_options) do
        nil -> base
        :lenient -> mode(:lenient)
        :strict -> mode(:strict)
        kw when is_list(kw) -> merge(base, kw)
        %__MODULE__{} = o -> o
      end

    base3 =
      case Keyword.get(call_opts, :mode) do
        :lenient -> mode(:lenient)
        :strict -> mode(:strict)
        _ -> base2
      end

    merge(base3, Keyword.take(call_opts, Map.keys(%__MODULE__{})))
  end
end
