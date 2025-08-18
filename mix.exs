defmodule Sifter.MixProject do
  use Mix.Project

  @source_url "https://github.com/typhoonworks/sifter"
  @version "0.1.0"

  def project do
    [
      app: :sifter,
      name: "Sifter",
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      docs: docs(),
      package: package(),
      description: description(),
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: dialyzer()
    ]
  end

  def cli do
    [preferred_envs: ["test.setup": :test, test: :test]]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto, "~> 3.10"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.20", optional: true},

      # Development and testing dependencies
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "test.setup": ["ecto.drop --quiet", "ecto.create", "ecto.migrate"],
      lint: ["format", "dialyzer"]
    ]
  end

  defp package do
    [
      name: "sifter",
      maintainers: ["Rui Freitas"],
      licenses: ["MIT"],
      links: %{GitHub: @source_url},
      files: ~w[lib .formatter.exs mix.exs README* LICENSE*]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit, :ecto, :ecto_sql, :postgrex],
      plt_core_path: "_build/#{Mix.env()}",
      flags: [:error_handling, :missing_return, :underspecs],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: docs_guides(),
      groups_for_modules: [
        Core: [Sifter, Sifter.Options, Sifter.Error],
        Lexer: [Sifter.Query.Lexer],
        Parser: [Sifter.Query.Parser, Sifter.AST, ~r/Sifter\.AST\..+/],
        Builder: [Sifter.Ecto.Builder],
        "Full-Text Search": [~r/Sifter\.FullText\..+/]
      ]
    ]
  end

  defp docs_guides do
    [
      "README.md",
      "guides/overview.md",
      "guides/installation.md",
      "guides/getting-started.md",
      "guides/query-syntax.md",
      "guides/configuration.md",
      "guides/full-text-search.md",
      "guides/integration-patterns.md",
      "guides/error-handling.md"
    ]
  end

  defp description do
    """
    Query filtering library for Elixir — transform frontend search queries into optimized Ecto queries with full-text search.
    """
  end
end
