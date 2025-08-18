# Integration Patterns

This guide covers tested patterns for integrating Sifter into real-world applications, focusing on result metadata usage and basic integration techniques.

## Understanding Result Metadata

Every Sifter query returns metadata alongside the Ecto query, providing valuable information about query characteristics and optimization opportunities.

### Metadata Structure

```elixir
{query, meta} = Sifter.filter!(Post, "machine learning status:published",
  schema: Post,
  search_fields: ["title", "content"],
  search_strategy: {:tsquery, "english"}
)

IO.inspect(meta)
# %{
#   uses_full_text?: true,
#   added_select_fields: [:search_rank],
#   recommended_order: [search_rank: :desc],
#   warnings: []
# }
```

### Metadata Fields

**`uses_full_text?: boolean()`**
- Indicates whether full-text search was applied
- Use to determine if ranking and relevance ordering is appropriate

**`added_select_fields: [atom()]`**
- Lists additional fields Sifter added to the SELECT clause
- Important for ensuring proper query handling

**`recommended_order: [{atom(), :asc | :desc}] | nil`**
- Suggested ORDER BY clauses for optimal results
- `nil` when no specific ordering is recommended

**`warnings: [map()]`**
- Contains warnings about ignored fields, type casting issues, etc.
- Useful for debugging and user feedback

## Phoenix Web Applications

### Basic Controller Pattern

```elixir
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller
  
  def index(conn, params) do
    query_string = params["q"] || ""
    
    {query, meta} = Sifter.filter!(Post, query_string,
      schema: Post,
      allowed_fields: allowed_fields(),
      search_fields: ["title", "content"],
      search_strategy: {:tsquery, "english"}
    )
    
    # Apply metadata-driven optimizations
    query = apply_ordering(query, meta)
    
    posts = Repo.all(query)
    
    render(conn, "index.html", 
      posts: posts, 
      meta: meta,
      query: query_string
    )
  end
  
  defp apply_ordering(query, meta) do
    if meta.uses_full_text? do
      order_by(query, [p], desc: p.search_rank, desc: p.inserted_at)
    else
      order_by(query, [p], desc: p.inserted_at)
    end
  end
  
  defp allowed_fields do
    [
      "status",
      "category", 
      "priority",
      %{as: "tag.name", field: "tags.name"},
      %{as: "authorName", field: "author.name"}
    ]
  end
end
```

### JSON API Pattern

```elixir
defmodule MyAppWeb.API.V1.PostController do
  use MyAppWeb, :controller
  
  def index(conn, params) do
    page_size = min(params["per_page"] || 20, 100)
    
    {query, meta} = Sifter.filter!(Post, params["q"],
      schema: Post,
      allowed_fields: api_allowed_fields(),
      search_fields: ["title", "content"],
      search_strategy: {:column, {"english", :searchable}},
      unknown_field: :warn  # Include warnings for API users
    )
    
    # Apply ordering and pagination
    posts = query
      |> apply_search_ordering(meta)
      |> limit(^page_size)
      |> Repo.all()
    
    json(conn, %{
      data: posts,
      meta: %{
        query: params["q"],
        uses_search_fields: meta.uses_full_text?,
        warnings: format_api_warnings(meta.warnings)
      }
    })
  end
  
  defp apply_search_ordering(query, %{uses_full_text?: true}) do
    order_by(query, [p], desc: p.search_rank, desc: p.id)
  end
  
  defp apply_search_ordering(query, _meta) do
    order_by(query, [p], desc: p.inserted_at, desc: p.id)
  end
  
  defp format_api_warnings(warnings) do
    Enum.map(warnings, fn warning ->
      %{
        type: warning.type,
        field: warning[:path] || warning[:field],
        message: "Unknown field ignored"
      }
    end)
  end
  
  defp api_allowed_fields do
    [
      "status",
      "category",
      %{as: "authorName", field: "author.name"},
      %{as: "tagName", field: "tags.name"}
    ]
  end
end
```

## Combining Sifter with Ecto Queries

### Pre-filtering with Business Logic

```elixir
defmodule MyApp.PostQueries do
  def user_accessible_posts(user, sifter_query) do
    # Start with user's accessible content
    base_query = from(p in Post,
      join: a in assoc(p, :author),
      where: a.organization_id == ^user.organization_id
    )
    
    # Apply Sifter filtering to the base query
    {filtered_query, meta} = Sifter.filter!(base_query, sifter_query,
      schema: Post,
      allowed_fields: ["status", "category", "tags.name"]
    )
    
    # Apply ordering based on search metadata
    final_query = if meta.uses_full_text? do
      order_by(filtered_query, [p], desc: p.search_rank, desc: p.created_at)
    else
      order_by(filtered_query, [p], desc: p.created_at)
    end
    
    {final_query, meta}
  end
end
```

### Adding Post-Sifter Constraints

```elixir
defmodule MyApp.ReportQueries do
  def filtered_entries(date_range, sifter_query) do
    {query, meta} = Sifter.filter!(Entry, sifter_query,
      schema: Entry,
      allowed_fields: ["status", "category", "user.name"]
    )
    
    # Add date range constraint after Sifter
    final_query = query
      |> where([e], e.created_at >= ^date_range.start_date)
      |> where([e], e.created_at <= ^date_range.end_date)
    
    {final_query, meta}
  end
end
```

## Error Handling

### Basic Error Handling

```elixir
defmodule MyAppWeb.SearchController do
  def index(conn, params) do
    case Sifter.filter(Post, params["q"], schema: Post) do
      {:ok, query, meta} ->
        posts = Repo.all(query)
        render(conn, "index.html", posts: posts, meta: meta, error: nil)
        
      {:error, error} ->
        # Log error and show user-friendly message
        Logger.warn("Search error: #{Exception.message(error)}")
        posts = []
        render(conn, "index.html", 
          posts: posts, 
          meta: %{}, 
          error: "Invalid search query"
        )
    end
  end
end
```

### Graceful Degradation

```elixir
defmodule MyAppWeb.SearchHelpers do
  def safe_search(schema, query_string, opts \\ []) do
    try do
      {query, meta} = Sifter.filter!(schema, query_string, opts)
      {:ok, query, meta}
    rescue
      Sifter.Error ->
        # Fall back to unfiltered query
        {:ok, schema, %{uses_full_text?: false, warnings: []}}
    end
  end
end

# Usage in controller
def index(conn, params) do
  {:ok, query, meta} = safe_search(Post, params["q"], 
    schema: Post,
    allowed_fields: ["status", "category"]
  )
  
  posts = Repo.all(query)
  render(conn, "index.html", posts: posts, meta: meta)
end
```

## Working with Metadata

### Using Recommended Ordering

```elixir
defmodule MyApp.SearchHelpers do
  def apply_recommended_ordering(query, meta) do
    case meta.recommended_order do
      nil ->
        # No specific ordering recommended, use default
        order_by(query, [r], desc: r.inserted_at)
        
      ordering ->
        # Apply recommended ordering
        Enum.reduce(ordering, query, fn {field, direction}, acc ->
          order_by(acc, [r], [{^direction, field(r, ^field)}])
        end)
    end
  end
end
```

### Handling Warnings

```elixir
defmodule MyAppWeb.SearchController do
  def index(conn, params) do
    {query, meta} = Sifter.filter!(Post, params["q"],
      schema: Post,
      allowed_fields: ["status"],
      unknown_field: :warn
    )
    
    # Show warnings to users in development
    if Mix.env() == :dev and not Enum.empty?(meta.warnings) do
      Logger.debug("Search warnings: #{inspect(meta.warnings)}")
    end
    
    posts = Repo.all(query)
    render(conn, "index.html", posts: posts, warnings: meta.warnings)
  end
end
```

## Field Aliasing Patterns

### Frontend-Friendly Field Names

```elixir
# Allow frontend to use user-friendly names
defmodule MyAppWeb.PostController do
  def index(conn, params) do
    {query, meta} = Sifter.filter!(Post, params["q"],
      schema: Post,
      allowed_fields: frontend_field_mapping()
    )
    
    # ... rest of controller
  end
  
  defp frontend_field_mapping do
    [
      # Frontend can use camelCase, maps to snake_case automatically
      "createdAt",        # -> created_at  
      "authorName",       # -> author_name (if field exists)
      
      # Custom mappings for different naming  
      %{as: "tag", field: "tags.name"},           # Singular vs plural
      %{as: "author", field: "author.name"},      # Simplified access
      %{as: "category", field: "post_category"}   # Different field names
    ]
  end
end
```

### Multi-version API Support

```elixir
defmodule MyAppWeb.API do
  def v1_field_mapping do
    [
      "status",
      "title",
      %{as: "authorId", field: "author_id"}
    ]
  end
  
  def v2_field_mapping do
    [
      "status", 
      "title",
      "category",
      %{as: "author.name", field: "author.name"},    # V2 allows author name filtering
      %{as: "tag.name", field: "tags.name"}          # V2 allows tag filtering
    ]
  end
end
```

This focused guide covers the tested and reliable patterns for integrating Sifter while avoiding untested advanced features.