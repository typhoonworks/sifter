# Installation

This guide walks you through adding Sifter to your Elixir application and configuring it for your specific use case.

## Prerequisites

Before installing Sifter, ensure you have:

- **Elixir 1.16+** and **Erlang/OTP 26+**
- **Ecto 3.10+** with **Ecto SQL 3.10+**
- **PostgreSQL database** (required for full-text search features)

## Adding to Your Project

Add Sifter to your `mix.exs` dependencies:

```elixir
defp deps do
  [
    {:sifter, "~> 0.1.0"},
    # Your existing dependencies
    {:ecto, "~> 3.10"},
    {:ecto_sql, "~> 3.10"},
    {:postgrex, "~> 0.20"}
  ]
end
```

Run the dependency installation:

```bash
mix deps.get
```

## Basic Configuration

Sifter works with your existing Ecto setup without additional configuration. However, you can customize its behavior through application config:

```elixir
# config/config.exs
config :sifter, :options,
  unknown_field: :ignore,     # :ignore | :warn | :error
  tsquery_mode: :plainto      # :plainto | :raw
```

### Configuration Options

- **`unknown_field`**: How to handle fields not in the allow-list
  - `:ignore` (default) - Silently skip unknown fields
  - `:warn` - Include warnings in metadata but continue
  - `:error` - Return error immediately
  
- **`tsquery_mode`**: PostgreSQL full-text search mode
  - `:plainto` (default) - Use `plainto_tsquery` (user-friendly)
  - `:raw` - Use `to_tsquery` (advanced syntax, requires sanitization)

## Database Setup for Full-Text Search

If you plan to use full-text search features, you'll need to prepare your PostgreSQL database.

### Option 1: ILIKE Strategy (Simple)

No database changes needed. Sifter will use `ILIKE` for text searches:

```elixir
Sifter.filter!(Post, "machine learning",
  schema: Post,
  search_fields: ["title", "content"],
  search_strategy: :ilike
)
```

### Option 2: Dynamic TSVector (Flexible)

Use PostgreSQL's `to_tsvector` function dynamically:

```elixir
Sifter.filter!(Post, "machine learning",
  schema: Post,
  search_fields: ["title", "content"],
  search_strategy: {:tsquery, "english"}
)
```

### Option 3: Pre-computed TSVector Column (Optimal Performance)

For best performance, add a dedicated tsvector column to your schemas:

```elixir
# Create migration
defmodule MyApp.Repo.Migrations.AddSearchableColumnToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :searchable, :tsvector
    end

    # Create GIN index for fast full-text search
    execute "CREATE INDEX posts_searchable_idx ON posts USING gin(searchable)"

    # Create trigger to automatically update searchable column
    execute """
    CREATE FUNCTION posts_searchable_trigger() RETURNS trigger AS $$
    BEGIN
      NEW.searchable := to_tsvector('english', 
        coalesce(NEW.title, '') || ' ' || coalesce(NEW.content, '')
      );
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER posts_searchable_update 
      BEFORE INSERT OR UPDATE ON posts 
      FOR EACH ROW EXECUTE FUNCTION posts_searchable_trigger();
    """

    # Update existing records
    execute """
    UPDATE posts SET searchable = to_tsvector('english', 
      coalesce(title, '') || ' ' || coalesce(content, '')
    )
    """
  end

  def down do
    execute "DROP TRIGGER posts_searchable_update ON posts"
    execute "DROP FUNCTION posts_searchable_trigger()"
    execute "DROP INDEX posts_searchable_idx"
    
    alter table(:posts) do
      remove :searchable
    end
  end
end
```

Then configure your schema:

```elixir
defmodule MyApp.Blog.Post do
  use Ecto.Schema
  
  schema "posts" do
    field :title, :string
    field :content, :text
    field :searchable, :string, virtual: true  # Don't select by default
    
    timestamps()
  end
end
```

Use the pre-computed column:

```elixir
Sifter.filter!(Post, "machine learning",
  schema: Post,
  search_strategy: {:column, {"english", :searchable}}
)
```

## Verifying Installation

Test your installation with a simple query:

```elixir
# In your IEx console
iex> alias MyApp.{Repo, Blog.Post}
iex> {query, meta} = Sifter.filter!(Post, "status:published")
iex> Repo.all(query)
```

You should see a filtered query executed without errors.

## Development Setup

For development and testing, you may want to use different configurations:

```elixir
# config/dev.exs
config :sifter, :options,
  unknown_field: :warn  # Show warnings during development

# config/test.exs
config :sifter, :options,
  unknown_field: :error  # Fail fast in tests

# config/prod.exs
config :sifter, :options,
  unknown_field: :ignore  # Lenient in production
```

## Next Steps

Now that Sifter is installed, continue with:

- [Getting Started](getting-started.md) - Your first queries
- [Query Syntax](query-syntax.md) - Complete syntax reference
- [Configuration](configuration.md) - Advanced configuration options