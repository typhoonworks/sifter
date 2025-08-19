# Configuration

This guide covers all available configuration options for Sifter, from basic setup to advanced customization.

## Configuration Hierarchy

Sifter uses a three-level configuration hierarchy (highest to lowest precedence):

1. **Per-call options** - Passed to `Sifter.filter/3` and `Sifter.filter!/2`
2. **Per-process/request defaults** - Set via `Process.put(:sifter_options, ...)`
3. **Application config** - Set in your application's configuration files

## Application-Wide Configuration

### Basic Configuration

Set default options in your application config:

```elixir
# config/config.exs
config :sifter, :options,
  unknown_field: :warn,      # :ignore | :warn | :error
  tsquery_mode: :plainto     # :plainto | :raw
```

### Mode-Based Configuration

Use predefined modes for common scenarios:

```elixir
# Lenient mode - ignore unknown fields, permissive behavior
config :sifter, :options, :lenient

# Strict mode - error on unknown fields and invalid operations  
config :sifter, :options, :strict

# Custom mode with specific overrides
config :sifter, :options, [
  mode: :strict,
  unknown_field: :warn  # Override strict mode for this option
]
```

### Environment-Specific Configuration

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

## Configuration Options Reference

### Error Handling Options

**`unknown_field`** - How to handle fields not in the allow-list
- `:ignore` (default) - Silently skip unknown fields
- `:warn` - Include warnings in metadata but continue processing  
- `:error` - Return error immediately on unknown field

```elixir
# Ignore unknown fields silently
Sifter.filter!(Post, "status:published unknownField:hack", 
  schema: Post,
  allowed_fields: ["status"],
  unknown_field: :ignore
)

# Include warnings in metadata
{query, meta} = Sifter.filter!(Post, "status:published unknownField:hack",
  schema: Post,
  allowed_fields: ["status"], 
  unknown_field: :warn
)
# meta.warnings will contain information about unknownField
```

**`unknown_assoc`** - How to handle unknown associations
- `:ignore` (default) - Silently skip unknown association paths
- `:warn` - Include warnings in metadata
- `:error` - Return error immediately

**`invalid_cast`** - How to handle type casting errors
- `:error` (default) - Return error on invalid values
- `:warn` - Include warnings but attempt to continue
- `:ignore` - Skip predicates with invalid values

```elixir
# Error on invalid type casting (default)
Sifter.filter(Post, "priority:not_a_number", 
  schema: Post,
  invalid_cast: :error
)
# Returns: {:error, %Sifter.Error{...}}

# Warn but continue processing
{query, meta} = Sifter.filter!(Post, "priority:not_a_number status:published",
  schema: Post,
  invalid_cast: :warn
) 
# meta.warnings contains casting error, query filters only by status
```

### Full-Text Search Configuration

**`tsquery_mode`** - PostgreSQL tsquery generation mode
- `:plainto` (default) - Uses `plainto_tsquery()` (user-friendly, handles most input safely)
- `:raw` - Uses `to_tsquery()` (advanced syntax, requires more careful sanitization)

```elixir
# Default plainto mode - handles most user input safely
config :sifter, :options,
  tsquery_mode: :plainto

# Raw mode - for advanced tsquery syntax
config :sifter, :options,
  tsquery_mode: :raw,
  full_text_sanitizer: &MyApp.CustomSanitizer.sanitize/1
```

**`full_text_sanitizer`** - Custom sanitization for full-text search terms
- `nil` (default) - Uses built-in sanitizer based on `tsquery_mode`
- `function/1` - Custom sanitization function
- `{module, function, args}` - MFA tuple for sanitization

```elixir
# Function sanitizer
config :sifter, :options,
  full_text_sanitizer: &MyApp.SearchSanitizer.clean/1

# MFA tuple sanitizer  
config :sifter, :options,
  full_text_sanitizer: {MyApp.SearchSanitizer, :sanitize_search, []}

# Per-call override
Sifter.filter!(Post, "machine learning",
  schema: Post,
  search_fields: ["title", "content"],
  full_text_sanitizer: &String.trim/1
)
```

### Future Configuration Options

The following options are planned for future implementation:

**`max_joins`** - Maximum number of association joins allowed *(not yet configurable)*
- Currently fixed at 1 level of association joins
- Will allow customization of join depth limits

**`join_overflow`** - How to handle exceeding max_joins *(to be implemented)*
- `:error` - Return error when limit exceeded
- `:ignore` - Silently ignore additional joins

**`empty_in`** - How to handle empty IN/NOT IN/ALL lists *(to be implemented)*
- `false` - Allow empty lists (results in no matches for IN, all matches for NOT IN/ALL)
- `true` - Allow and optimize empty lists
- `:error` - Return error on empty lists

## Per-Process Configuration

Set default options for the current process (useful in Plugs or middleware):

```elixir
# In a Phoenix plug or controller
defmodule MyAppWeb.SifterPlug do
  def call(conn, _opts) do
    # Set lenient defaults for web requests
    Process.put(:sifter_options, [unknown_field: :ignore])
    conn
  end
end

# In a background job
defmodule MyApp.ReportJob do
  def perform(query) do
    # Use strict validation for internal queries
    Process.put(:sifter_options, :strict)
    
    Sifter.filter!(Report, query, schema: Report)
  end
end
```

## Per-Call Configuration

Override defaults for specific calls:

```elixir
# Strict validation for this query only
{query, meta} = Sifter.filter!(Post, user_input,
  schema: Post,
  allowed_fields: ["status", "category"],
  unknown_field: :error,  # Override default
  tsquery_mode: :raw      # Override default
)
```

## Full-Text Search Strategies

### ILIKE Strategy (Simple)

Basic pattern matching across text fields:

```elixir
Sifter.filter!(Post, "elixir programming",
  schema: Post,
  search_fields: ["title", "content"],
  search_strategy: :ilike
)
```

### TSQuery Strategy (Dynamic)

PostgreSQL full-text search using dynamic tsvector generation:

```elixir
Sifter.filter!(Post, "elixir & programming", 
  schema: Post,
  search_fields: ["title", "content"],
  search_strategy: {:tsquery, "english"},
  tsquery_mode: :raw  # For advanced tsquery syntax
)
```

### Pre-computed TSVector Column

Use a dedicated tsvector column for optimal performance:

```elixir
Sifter.filter!(Post, "elixir programming",
  schema: Post, 
  search_strategy: {:column, {"english", :searchable}},
  tsquery_mode: :plainto
)
```

## Custom Sanitization

### Built-in Sanitizers

Sifter includes two built-in sanitizers:

```elixir
# Basic sanitizer (used with :plainto mode)
Sifter.FullText.Sanitizers.Basic.sanitize_plainto("user input!")

# Strict sanitizer (used with :raw mode)  
Sifter.FullText.Sanitizers.Strict.sanitize_tsquery("user & input")
```

### Custom Sanitizer Examples

```elixir
defmodule MyApp.SearchSanitizer do
  def sanitize_search(term) do
    term
    |> String.trim()
    |> String.replace(~r/[^\w\s]/, "") # Remove special chars
    |> String.slice(0, 100)            # Limit length
  end
  
  def sanitize_with_stemming(term) do
    # Custom logic with stemming, etc.
    term
    |> sanitize_search()
    |> apply_stemming()
  end
  
  defp apply_stemming(term) do
    # Your stemming logic here
    term
  end
end

# Use in configuration
config :sifter, :options,
  full_text_sanitizer: {MyApp.SearchSanitizer, :sanitize_with_stemming, []}
```

## Complete Configuration Example

```elixir
# config/config.exs
config :sifter, :options, [
  # Error handling
  unknown_field: :warn,
  unknown_assoc: :ignore, 
  invalid_cast: :error,
  
  # Full-text search  
  tsquery_mode: :plainto,
  full_text_sanitizer: {MyApp.SearchSanitizer, :clean_input, []}
]
```

## Advanced Use Cases

### Multi-Tenant Applications

```elixir
defmodule MyAppWeb.TenantSifterPlug do
  def call(conn, _opts) do
    tenant = get_current_tenant(conn)
    
    # Configure based on tenant
    sifter_opts = case tenant.plan do
      :premium -> [unknown_field: :warn]
      :basic   -> [unknown_field: :ignore] 
      :free    -> :strict  # Very restrictive
    end
    
    Process.put(:sifter_options, sifter_opts)
    conn
  end
end
```

### API Versioning

```elixir
defmodule MyAppWeb.V2.PostController do
  def index(conn, params) do
    # V2 API uses stricter validation
    {query, meta} = Sifter.filter!(Post, params["q"],
      schema: Post,
      allowed_fields: api_v2_allowed_fields(),
      unknown_field: :error,  # V2 is strict
      search_strategy: {:tsquery, "english"}
    )
    
    render(conn, "index.json", posts: Repo.all(query), meta: meta)
  end
end
```

### Development Helpers

```elixir
# config/dev.exs - Show all warnings during development
config :sifter, :options, [
  unknown_field: :warn,
  unknown_assoc: :warn, 
  invalid_cast: :warn
]

# lib/my_app/dev_helpers.ex
defmodule MyApp.DevHelpers do
  def debug_sifter_query(query_string, schema) do
    {ecto_query, meta} = Sifter.filter!(schema, query_string,
      schema: schema,
      unknown_field: :warn
    )
    
    IO.puts("=== Sifter Debug ===")
    IO.puts("Query: #{query_string}")
    IO.puts("Warnings: #{inspect(meta.warnings)}")
    IO.puts("Uses full-text: #{meta.uses_full_text?}")
    IO.puts("SQL: #{inspect(Repo.to_sql(:all, ecto_query))}")
    
    {ecto_query, meta}
  end
end
```

This configuration system allows you to tailor Sifter's behavior to your application's specific needs while maintaining sensible defaults for common use cases.