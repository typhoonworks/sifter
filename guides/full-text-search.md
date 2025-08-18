# Full-Text Search

This guide covers setting up and using PostgreSQL full-text search capabilities with Sifter.

## Overview

Sifter provides three strategies for full-text search, each with different performance characteristics and setup requirements:

1. **ILIKE Strategy** - Simple pattern matching (works with any database)
2. **TSQuery Strategy** - Dynamic PostgreSQL full-text search
3. **Pre-computed TSVector Column** - Optimal performance with dedicated search columns

## Database Requirements

### PostgreSQL Version
- **PostgreSQL 9.1+** required for basic full-text features
- **PostgreSQL 12+** recommended for optimal performance and features

### Required Extensions
Most full-text features are built into PostgreSQL core, but you may want these extensions:

```sql
-- For advanced text processing (optional)
CREATE EXTENSION IF NOT EXISTS unaccent;

-- For additional language support (optional)  
CREATE EXTENSION IF NOT EXISTS dict_xsyn;
```

## Strategy 1: ILIKE (Simple)

The ILIKE strategy works with any database that supports case-insensitive LIKE operations.

### Setup
No special database setup required.

### Usage
```elixir
{query, meta} = Sifter.filter!(Post, "elixir programming",
  schema: Post,
  search_fields: ["title", "content"],
  search_strategy: :ilike
)
```

### Generated SQL
```sql
SELECT * FROM posts 
WHERE (title ILIKE '%elixir%' OR content ILIKE '%elixir%') 
  AND (title ILIKE '%programming%' OR content ILIKE '%programming%')
```

### Performance Characteristics
- ✅ Works with any database
- ✅ No setup required
- ✅ Simple and predictable
- ❌ No ranking or relevance scoring
- ❌ Slower on large datasets
- ❌ No stemming or linguistic features

## Strategy 2: TSQuery (Dynamic)

Uses PostgreSQL's `to_tsvector()` and `plainto_tsquery()` functions dynamically.

### Setup
No special database setup required beyond PostgreSQL.

### Usage
```elixir
{query, meta} = Sifter.filter!(Post, "elixir programming",
  schema: Post,
  search_fields: ["title", "content"],
  search_strategy: {:tsquery, "english"}
)
```

### Generated SQL
```sql
SELECT * FROM posts 
WHERE (to_tsvector('english', coalesce(title, '')) @@ plainto_tsquery('english', 'elixir programming'))
   OR (to_tsvector('english', coalesce(content, '')) @@ plainto_tsquery('english', 'elixir programming'))
```

### Performance Characteristics
- ✅ Built-in stemming and language support
- ✅ Better search quality than ILIKE
- ✅ No additional schema changes required
- ❌ Slower than pre-computed columns
- ❌ No persistent ranking
- ❌ Heavy CPU usage on large text fields

### Advanced TSQuery Syntax

Use `:raw` mode for advanced search operators:

```elixir
{query, meta} = Sifter.filter!(Post, "elixir & (phoenix | liveview)",
  schema: Post,
  search_fields: ["title", "content"],
  search_strategy: {:tsquery, "english"},
  tsquery_mode: :raw
)
```

**TSQuery operators:**
- `&` - AND (both terms must be present)
- `|` - OR (either term can be present)  
- `!` - NOT (term must not be present)
- `<->` - followed by (terms must be adjacent)
- `<N>` - distance (terms within N words)

## Strategy 3: Pre-computed TSVector Column (Recommended)

Uses dedicated tsvector columns for optimal performance and ranking.

### Database Setup

#### 1. Add TSVector Column

```elixir
# Create migration
defmodule MyApp.Repo.Migrations.AddSearchableToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :searchable, :tsvector
    end
  end

  def down do
    alter table(:posts) do
      remove :searchable
    end
  end
end
```

#### 2. Create GIN Index

```elixir
defmodule MyApp.Repo.Migrations.AddSearchIndexToPosts do
  use Ecto.Migration

  def up do
    # GIN index for fast full-text search
    execute "CREATE INDEX posts_searchable_idx ON posts USING gin(searchable)"
  end

  def down do
    execute "DROP INDEX posts_searchable_idx"
  end
end
```

#### 3. Create Update Trigger

```elixir
defmodule MyApp.Repo.Migrations.AddSearchTriggerToPosts do
  use Ecto.Migration

  def up do
    # Function to update searchable column
    execute """
    CREATE OR REPLACE FUNCTION posts_searchable_trigger() RETURNS trigger AS $$
    BEGIN
      NEW.searchable := to_tsvector('english', 
        coalesce(NEW.title, '') || ' ' || 
        coalesce(NEW.content, '') || ' ' ||
        coalesce(NEW.tags, '')
      );
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    # Trigger to automatically update searchable column
    execute """
    CREATE TRIGGER posts_searchable_update 
      BEFORE INSERT OR UPDATE ON posts 
      FOR EACH ROW EXECUTE FUNCTION posts_searchable_trigger();
    """

    # Update existing records
    execute """
    UPDATE posts SET searchable = to_tsvector('english', 
      coalesce(title, '') || ' ' || 
      coalesce(content, '') || ' ' ||
      coalesce(tags, '')
    )
    """
  end

  def down do
    execute "DROP TRIGGER posts_searchable_update ON posts"
    execute "DROP FUNCTION posts_searchable_trigger()"
  end
end
```

#### 4. Update Schema

```elixir
defmodule MyApp.Blog.Post do
  use Ecto.Schema
  
  schema "posts" do
    field :title, :string
    field :content, :text
    field :tags, :string
    field :searchable, :string, virtual: true  # Don't select by default
    
    timestamps()
  end
end
```

### Usage with Pre-computed Column

```elixir
{query, meta} = Sifter.filter!(Post, "elixir programming",
  schema: Post,
  search_strategy: {:column, {"english", :searchable}}
)
```

### Generated SQL with Ranking

```sql
SELECT p0.*, 
       ts_rank_cd(p0.searchable, plainto_tsquery('english', 'elixir programming'), 4) AS search_rank
FROM posts AS p0 
WHERE p0.searchable @@ plainto_tsquery('english', 'elixir programming')
ORDER BY search_rank DESC
```

### Performance Characteristics
- ✅ Fastest search performance
- ✅ Built-in relevance ranking
- ✅ Efficient index usage
- ✅ Supports complex queries
- ❌ Requires schema changes
- ❌ Additional storage overhead
- ❌ Trigger maintenance complexity

## Language Configuration

### Supported Languages

PostgreSQL supports many languages out of the box:

```sql
-- List available configurations
SELECT cfgname FROM pg_ts_config;

-- Common languages: english, spanish, french, german, italian, portuguese, etc.
```

### Using Different Languages

```elixir
# Spanish language configuration
{query, meta} = Sifter.filter!(Post, "programación elixir",
  schema: Post,
  search_fields: ["title", "content"],
  search_strategy: {:tsquery, "spanish"}
)

# Multi-language setup (requires custom configuration)
{query, meta} = Sifter.filter!(Post, "programming",
  schema: Post,
  search_strategy: {:column, {"multilingual", :searchable}}
)
```

### Custom Language Configurations

```sql
-- Create custom multi-language configuration
CREATE TEXT SEARCH CONFIGURATION multilingual (COPY = english);
-- Add additional language support as needed
```

## Advanced Full-Text Features

### Ranking and Ordering

When using TSVector columns, Sifter automatically adds ranking:

```elixir
{query, meta} = Sifter.filter!(Post, "elixir phoenix",
  schema: Post,
  search_strategy: {:column, {"english", :searchable}}
)

# meta.uses_full_text? == true
# meta.added_select_fields == [:search_rank] 
# meta.recommended_order == [search_rank: :desc]

# Apply recommended ordering
posts = query
  |> order_by([p], desc: p.search_rank, desc: p.inserted_at)
  |> Repo.all()
```

### Combining with Field Filters

```elixir
# Full-text search with field constraints
{query, meta} = Sifter.filter!(Post, "elixir status:published author.name:jose",
  schema: Post,
  allowed_fields: ["status", "author.name"],
  search_fields: ["title", "content"],
  search_strategy: {:column, {"english", :searchable}}
)
```

### Custom Ranking

For manual ranking control:

```elixir
defmodule MyApp.SearchQueries do
  def search_posts(term, opts \\ []) do
    {query, meta} = Sifter.filter!(Post, term,
      schema: Post,
      search_strategy: {:column, {"english", :searchable}}
    )
    
    if meta.uses_full_text? do
      # Custom ranking with boost for recent posts
      query
      |> select_merge([p], %{
        final_rank: fragment(
          "? * 0.8 + (EXTRACT(EPOCH FROM ?) / 86400) * 0.2",
          p.search_rank,
          p.inserted_at
        )
      })
      |> order_by([p], desc: p.final_rank)
    else
      order_by(query, [p], desc: p.inserted_at)
    end
  end
end
```

## Performance Tuning

### Index Optimization

```sql
-- Monitor index usage
SELECT schemaname, tablename, indexname, idx_scan, idx_tup_read, idx_tup_fetch 
FROM pg_stat_user_indexes 
WHERE indexname = 'posts_searchable_idx';

-- Check index size
SELECT pg_size_pretty(pg_relation_size('posts_searchable_idx'));
```

### Query Performance Analysis

```sql
-- Analyze query performance
EXPLAIN (ANALYZE, BUFFERS) 
SELECT * FROM posts 
WHERE searchable @@ plainto_tsquery('english', 'elixir programming')
ORDER BY ts_rank_cd(searchable, plainto_tsquery('english', 'elixir programming'), 4) DESC;
```

### TSVector Column Maintenance

```sql
-- Reindex if needed (rarely required)
REINDEX INDEX posts_searchable_idx;

-- Update statistics
ANALYZE posts;

-- Check for bloated indexes
SELECT schemaname, tablename, attname, null_frac, avg_width, n_distinct
FROM pg_stats 
WHERE tablename = 'posts' AND attname = 'searchable';
```

## Troubleshooting

### Common Issues

**Search returns no results:**
```sql
-- Check if tsvector column has data
SELECT title, searchable FROM posts WHERE searchable IS NULL LIMIT 5;

-- Test tsquery syntax
SELECT plainto_tsquery('english', 'your search term');
```

**Poor ranking quality:**
```sql
-- Check ranking distribution
SELECT title, ts_rank_cd(searchable, plainto_tsquery('english', 'term'), 4) as rank
FROM posts 
WHERE searchable @@ plainto_tsquery('english', 'term')
ORDER BY rank DESC
LIMIT 10;
```

**Trigger not updating:**
```sql
-- Test trigger function manually
UPDATE posts SET title = title WHERE id = 1;

-- Check trigger exists
SELECT tgname FROM pg_trigger WHERE tgrelid = 'posts'::regclass;
```

### Performance Issues

**Slow search queries:**
- Ensure GIN index exists and is being used
- Check if tsvector column is properly maintained
- Consider using simpler search terms
- Monitor index bloat

**High CPU usage:**
- Use pre-computed columns instead of dynamic TSQuery
- Limit search term complexity
- Add query timeouts

### Migration from Other Strategies

**From ILIKE to TSQuery:**
```elixir
# Before
search_strategy: :ilike

# After - no schema changes needed
search_strategy: {:tsquery, "english"}
```

**From TSQuery to Pre-computed Column:**
```elixir
# 1. Run migrations to add tsvector column and triggers
# 2. Update configuration
# Before
search_strategy: {:tsquery, "english"}

# After
search_strategy: {:column, {"english", :searchable}}
```

This comprehensive setup enables sophisticated full-text search capabilities while maintaining excellent performance for your Sifter-powered applications.