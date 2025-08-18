# Getting Started

This guide will walk you through your first Sifter queries, from basic filtering to advanced full-text search.

## Prerequisites

Before starting, make sure you have:

- Completed the [Installation](installation.md) guide
- A running Elixir application with Ecto and Sifter configured
- Some data in your database to query

## Your First Query

### Basic Filtering

Let's start with a simple field-based filter:

```elixir
# Filter posts by status
{query, meta} = Sifter.filter!(Post, "status:published", schema: Post)
results = Repo.all(query)
```

This generates an Ecto query equivalent to:
```elixir
from p in Post, where: p.status == "published"
```

### Multiple Conditions

Combine multiple filters with implicit AND:

```elixir
# Multiple field filters (implicit AND)
{query, meta} = Sifter.filter!(Post, "status:published category:tech",
  schema: Post
)
```

### Comparison Operators

Use comparison operators for numeric and date fields:

```elixir
# Posts with high priority, created recently
{query, meta} = Sifter.filter!(Post, "priority>5 createdAt>=2024-01-01",
  schema: Post
)

# Various comparison operators
{query, meta} = Sifter.filter!(Post, "views>1000 rating<=4.5 createdAt<2024-01-01",
  schema: Post
)
```

## Automatic camelCase Conversion

Sifter automatically converts camelCase field names to snake_case database columns, making it perfect for JSON APIs and GraphQL:

```elixir
# Users can query with camelCase - Sifter converts automatically
{query, meta} = Sifter.filter!(Post, "createdAt>=2024-01-01 authorId:123",
  schema: Post
)
# Becomes: created_at >= '2024-01-01' AND author_id = 123
```

This means frontend applications can use their natural camelCase conventions without any conversion needed.

## Working with Associations

### Filtering Through Relationships

Filter records based on related data using dot notation:

```elixir
# Posts by specific author
{query, meta} = Sifter.filter!(Post, "author.name:john",
  schema: Post,
  allowed_fields: ["status", "author.name"]
)

# Posts with specific tags
{query, meta} = Sifter.filter!(Post, "tags.name:elixir",
  schema: Post,
  allowed_fields: ["status", "tags.name"]
)
```

Sifter automatically handles the necessary joins and applies `DISTINCT` when needed for many-to-many relationships.

## Boolean Logic

### AND and OR Operations

Combine conditions with explicit boolean operators:

```elixir
# Explicit OR
{query, meta} = Sifter.filter!(Post, "status:draft OR status:review",
  schema: Post
)

# Mixed AND/OR with precedence
{query, meta} = Sifter.filter!(Post, "priority>3 AND (status:draft OR status:review)",
  schema: Post
)
```

### Negation

Exclude records with NOT:

```elixir
# Exclude archived posts
{query, meta} = Sifter.filter!(Post, "NOT status:archived",
  schema: Post
)

# Shorthand negation with dash
{query, meta} = Sifter.filter!(Post, "-spam category:tech",
  schema: Post
)
```

## Set Operations

### IN and NOT IN

Filter by multiple values:

```elixir
# Posts in multiple categories
{query, meta} = Sifter.filter!(Post, "category IN (tech, science, elixir)",
  schema: Post
)

# Exclude multiple statuses
{query, meta} = Sifter.filter!(Post, "status NOT IN (archived, deleted)",
  schema: Post
)
```

## Wildcard Matching

### Prefix and Suffix Searches

Use wildcards for pattern matching with the equality operator:

```elixir
# Titles starting with "Introduction"
{query, meta} = Sifter.filter!(Post, "title:Introduction*",
  schema: Post
)

# Titles ending with "Guide"
{query, meta} = Sifter.filter!(Post, "title:*Guide",
  schema: Post
)
```

**Note**: Wildcards only work with the `:` (equality) operator and are not allowed in the middle of terms.

## Full-Text Search

### Basic Full-Text

Perform text searches across multiple fields:

```elixir
# Search for "machine learning" across title and content
{query, meta} = Sifter.filter!(Post, "machine learning",
  schema: Post,
  search_fields: ["title", "content"],
  search_strategy: :ilike
)
```

### Combined Field and Full-Text

Mix field filters with full-text search:

```elixir
# Published posts containing "elixir"
{query, meta} = Sifter.filter!(Post, "status:published elixir",
  schema: Post,
  search_fields: ["title", "content"]
)
```

### PostgreSQL Full-Text Search

Use PostgreSQL's advanced full-text capabilities:

```elixir
# TSVector search with ranking
{query, meta} = Sifter.filter!(Post, "functional programming",
  schema: Post,
  search_fields: ["title", "content"],
  search_strategy: {:tsquery, "english"}
)

# Check if ranking is available
if meta.uses_full_text? do
  query = query |> order_by([p], desc: p.search_rank)
end
```

## Access Control with Allow-Lists

### Restricting Allowed Fields

Control which fields users can filter by:

```elixir
# Only allow specific fields
{query, meta} = Sifter.filter!(Post, "status:published secretField:hacker",
  schema: Post,
  allowed_fields: ["status", "category", "author.name"]  # secretField ignored
)
```

### Field Aliasing for Different Resource Names

Map user-facing field names to actual database fields when they differ:

```elixir
# GraphQL schema uses different names than database
{query, meta} = Sifter.filter!(Post, "tag.name:elixir team.name:acme",
  schema: Post,
  allowed_fields: [
    "status",
    %{as: "tag.name", field: "tags.name"},           # Singular vs plural
    %{as: "team.clientName", field: "organization.name"}  # Different table naming
  ]
)

# API presents user-friendly names
{query, meta} = Sifter.filter!(Order, "customer:john totalAmount>100",
  schema: Order,
  allowed_fields: [
    %{as: "customer", field: "customer.name"},       # Simplified field name
    %{as: "totalAmount", field: "total_cents"},      # Different representation
    "status"
  ]
)
```

## Error Handling

### Graceful Error Handling

Handle malformed queries gracefully:

```elixir
case Sifter.filter(Post, "invalid syntax ((", schema: Post) do
  {:ok, query, meta} ->
    Repo.all(query)

  {:error, %Sifter.Error{stage: :parse, reason: reason}} ->
    # Handle parsing error
    Logger.warn("Invalid query syntax: #{inspect(reason)}")
    Repo.all(Post)  # Return unfiltered results

  {:error, %Sifter.Error{stage: :build, reason: reason}} ->
    # Handle build error (e.g., unknown field)
    Logger.warn("Query build failed: #{inspect(reason)}")
    Repo.all(Post)
end
```

### Strict vs Lenient Mode

Configure how Sifter handles unknown fields:

```elixir
# Lenient: ignore unknown fields
{query, meta} = Sifter.filter!(Post, "status:published unknownField:value",
  schema: Post,
  allowed_fields: ["status"],
  mode: :lenient
)

# Strict: error on unknown fields
case Sifter.filter(Post, "status:published unknownField:value",
  schema: Post,
  allowed_fields: ["status"],
  mode: :strict
) do
  {:ok, query, meta} -> Repo.all(query)
  {:error, error} -> # Handle unknown field error
end
```

## Understanding Query Metadata

Sifter returns metadata about the generated query:

```elixir
{query, meta} = Sifter.filter!(Post, "machine learning status:published",
  schema: Post,
  search_fields: ["title", "content"],
  search_strategy: {:tsquery, "english"}
)

# Check what Sifter added to your query
IO.inspect(meta)
# %{
#   uses_full_text?: true,
#   added_select_fields: [:search_rank],
#   recommended_order: [search_rank: :desc],
#   warnings: []
# }
```

Use metadata to enhance your queries:

```elixir
# Apply recommended ordering for full-text search
query = if meta.uses_full_text? do
  order_by(query, [p], desc: p.search_rank, desc: p.inserted_at)
else
  order_by(query, [p], desc: p.inserted_at)
end

results = Repo.all(query)
```

## Real-World Example

Here's how you might use Sifter in a Phoenix controller:

```elixir
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  def index(conn, params) do
    query_string = params["q"] || ""

    {query, meta} = Sifter.filter!(Post, query_string,
      schema: Post,
      allowed_fields: [
        "status",
        "category",
        "priority",
        %{as: "tag.name", field: "tags.name"},  # Singular for ergonomics
        "author.name"
      ],
      search_fields: ["title", "content"],
      search_strategy: {:tsquery, "english"}
    )

    # Apply ordering based on search context
    query = if meta.uses_full_text? do
      order_by(query, [p], desc: p.search_rank, desc: p.inserted_at)
    else
      order_by(query, [p], desc: p.inserted_at)
    end

    posts = Repo.all(query)

    render(conn, "index.html", posts: posts, meta: meta)
  end
end
```

## Next Steps

Now that you understand the basics, explore:

- [Query Syntax](query-syntax.md) - Complete syntax reference
- [Configuration](configuration.md) - Advanced configuration options
- [Full-Text Search](full-text-search.md) - PostgreSQL full-text setup
- [Integration Patterns](integration-patterns.md) - Real-world usage patterns
