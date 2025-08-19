# Overview

Sifter is an Elixir library that transforms search query strings into optimized Ecto database queries. Inspired by Shopify's search syntax used in their REST APIs, it provides a flexible query language for filtering data with support for field-based predicates, full-text search, boolean logic, and wildcard matching—all while maintaining type safety and security.

## Why Sifter?

Modern applications need flexible query capabilities that don't require constant backend changes. When building GraphQL or REST APIs, frontend teams need the ability to:

- Filter records by specific field values without new API endpoints
- Perform text searches across multiple fields dynamically
- Combine multiple conditions with AND/OR logic
- Use wildcards and comparison operators
- Search related data through associations

This library was born from the need to give React frontends flexible query options without constantly tweaking API parameters. Instead of hardcoding filter combinations, frontend clients can build query strings that express exactly what they need.

However, building these features safely and efficiently presents several challenges:

### 🔐 Security Concerns
- **SQL injection prevention**: Dynamic query building must be injection-proof
- **Field access control**: Users should only filter by allowed fields
- **Input validation**: Malformed queries should be caught before hitting the database

### ⚡ Performance Issues  
- **Query optimization**: Hand-written dynamic queries can be inefficient
- **Full-text search**: Implementing PostgreSQL's tsvector features correctly is complex
- **Association handling**: Joining related tables safely while avoiding N+1 problems

### 🛠️ Developer Experience
- **Maintenance burden**: Custom query builders become complex over time
- **Type safety**: Dynamic queries often bypass Ecto's type casting
- **Debugging difficulty**: Complex dynamic SQL is hard to troubleshoot

## How Sifter Solves These Problems

### Safe Query Language
Sifter provides a structured query language that feels natural to users while remaining safe:

```
status:active priority:>3 urgent
```

This query filters for records where `status` equals "active", `priority` is greater than 3, and performs a full-text search for "urgent" across configured fields.

### Automatic Security
- **Allow-lists**: Explicitly control which fields users can filter by
- **Type casting**: All values are cast to proper Ecto types
- **SQL injection protection**: Built on Ecto's dynamic query system
- **Field aliasing**: Map user-facing field names to internal schema fields

### PostgreSQL-First Design
Sifter is built specifically for PostgreSQL applications and provides:
- **Native tsvector support**: Efficient full-text search with ranking
- **Optimized joins**: Automatic DISTINCT for many-to-many relationships
- **Index-friendly queries**: Generated SQL works well with database indexes

### Rich Configuration Options
- **Multiple full-text strategies**: ILIKE for simplicity, tsvector for performance
- **Flexible error handling**: Choose between lenient and strict validation modes
- **Custom sanitization**: Pluggable sanitizers for full-text search terms
- **Association support**: Filter through belongs_to, has_many, and many_to_many

## Core Features

### Field-Based Filtering
Support for all standard comparison operations:
- **Equality**: `status:published`
- **Comparison**: `priority:>5`, `created_at:<=2024-01-01`
- **Set membership**: `category IN (news, blog)`, `type NOT IN (archived)`, `labels ALL (urgent, backend)`
- **Wildcards**: `title:acme*` (starts with), `title:*corp` (ends with)

### Boolean Logic
Combine conditions with natural operators:
- **AND logic**: `status:live priority:high` (implicit AND)
- **OR logic**: `status:draft OR status:review`
- **Negation**: `NOT urgent` or `-spam`
- **Grouping**: `(status:draft OR status:review) priority:>3`

### Full-Text Search
Multiple strategies for text search:
- **Simple ILIKE**: Case-insensitive pattern matching
- **PostgreSQL tsvector**: Advanced full-text search with ranking
- **Custom sanitization**: Clean user input safely

### Association Support
Filter through related data:
- **One-level paths**: `organization.name:acme`, `tags.name:urgent`
- **Automatic joins**: Sifter handles the complexity of joining tables
- **Proper aliasing**: Map frontend field names to database relationships

## Automatic Field Name Conversion

Sifter automatically converts camelCase field names to snake_case, making it perfect for:
- **JSON APIs**: Users can search with `createdAt:>2024-01-01`
- **GraphQL interfaces**: Maintain consistent field naming conventions
- **Frontend integration**: No need to transform field names in client code

## Result Metadata

Sifter provides rich metadata about generated queries:
- **Full-text usage**: Know when ranking should be applied
- **Additional fields**: Get required SELECT fields for ranking
- **Recommended ordering**: Automatic suggestions for search result ranking
- **Warnings**: Optional feedback about ignored or problematic fields

## PostgreSQL Requirement

Sifter is designed specifically for PostgreSQL applications. While the basic filtering works with any database Ecto supports, the full-text search features require PostgreSQL's:
- `tsvector` and `tsquery` types
- `to_tsvector()` and `plainto_tsquery()` functions  
- Full-text indexing capabilities

If you're using MySQL or SQLite, you can still use Sifter's filtering features, but full-text search will fall back to simple ILIKE pattern matching.

## When to Use Sifter

Sifter is ideal for:

### GraphQL and REST APIs
Give frontend applications flexible query capabilities without constant backend changes:
```elixir
# Frontend sends: {"query": "category:tech createdAt:>2024-01-01"}
{query, meta} = Sifter.filter!(Post, params["query"], 
  schema: Post,
  allowed_fields: ["category", "created_at", "author.name"]
)
```

### Admin Interfaces
Provide comprehensive search and filtering tools:
```elixir
# Search entries with multiple criteria
Sifter.filter!(Entry, "status:published author.name:john urgent")
```

### Search Features
Build sophisticated search interfaces with full-text capabilities:
```elixir
# Full-text search with field filters
Sifter.filter!(Article, "machine learning status:published", 
  schema: Article,
  search_fields: ["title", "content"],
  search_strategy: {:column, {"english", :searchable}}
)
```

### Data Exploration
Enable complex filtering for reports and analytics:
```elixir
# Complex filtering for reports
Sifter.filter!(Order, "(status:completed OR status:shipped) total:>100", 
  schema: Order,
  allowed_fields: ["status", "total", "customer.tier"]
)
```

## What's Next?

Continue with the [Installation Guide](installation.md) to add Sifter to your application, then check out [Getting Started](getting-started.md) for your first queries.