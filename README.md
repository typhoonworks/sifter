# Sifter

<p>
  <a href="https://hex.pm/packages/sifter">
    <img alt="Hex Version" src="https://img.shields.io/hexpm/v/sifter.svg">
  </a>
  <a href="https://hexdocs.pm/sifter">
    <img src="https://img.shields.io/badge/docs-hexdocs-blue" alt="HexDocs">
  </a>
  <a href="https://github.com/yourusername/sifter/actions">
    <img alt="CI Status" src="https://github.com/yourusername/sifter/workflows/ci/badge.svg">
  </a>
</p>

Sifter is a query filtering library for Elixir that gives your frontend applications the power to build flexible queries without constantly tweaking backend parameters. It transforms simple query strings into optimized Ecto queries with full-text search support.

> 🚧 **Early Release**: This library is fresh out of the oven! The API isn't locked in stone yet, and we're actively looking for feedback on how to make it better. Your suggestions and use cases are welcome!

## Why Sifter?

While working on [Accomplish](https://accomplish.dev), we needed advanced filtering capabilities for our application. We kept having to modify backend parameters every time the frontend needed new search functionality. At one point, adding a frontend filtering improvement meant compromising on existing filtering behavior - not ideal!

This reminded me of a Ruby gem I had built for an enterprise GraphQL API, which itself was inspired by Shopify's search syntax. That gem solved these exact problems by giving the frontend a flexible query language instead of rigid parameters. So I brought that same approach to Elixir, and Sifter was born.

The Elixir ecosystem has a gap when it comes to actively maintained filtering libraries. There's Ash Framework with its filtering capabilities, but if you're not using Ash, you need something standalone. That's where Sifter comes in.

## Features

- 🎯 **Frontend-friendly syntax**: Let your React/Vue/Angular apps build queries naturally
- 🐘 **PostgreSQL-first**: Built for PostgreSQL because that's what we use and love
- 🔍 **Full-text search**: Real PostgreSQL tsvector support, not just ILIKE
- 🔒 **Security built-in**: Field allow-lists guard what fields can be exposed
- 🐍 **Automatic case conversion**: camelCase from frontend → snake_case in database
- 📊 **Smart metadata**: Know when to apply ranking, what fields were added, etc.

## Quick Example

```elixir
# Your frontend sends: {"q": "machine learning status:published createdAt:>2024-01-01"}

{query, meta} = Sifter.filter!(Post, params["q"],
  schema: Post,
  allowed_fields: ["status", "createdAt", "author.name"],
  search_fields: ["title", "content"],
  search_strategy: {:tsquery, "english"}
)

posts = Repo.all(query)
# That's it! No parameter wrangling, no SQL building, no headaches.
```

## Installation

Add `sifter` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:sifter, "~> 0.1.0"}
  ]
end
```

## Local Development

### Quick Start with Docker

The easiest way to get started is using the included Docker Compose setup:

```bash
# Clone the repository
git clone https://github.com/typhoonworks/sifter.git
cd sifter

# Start PostgreSQL (includes Adminer for database inspection)
docker compose up -d

# Install dependencies
mix deps.get

# Setup test database
MIX_ENV=test mix ecto.setup

# Run tests
mix test
```

The Docker setup includes:
- **PostgreSQL 15.8** on port `2345` (to avoid conflicts with your local PostgreSQL)
- **Adminer** on port `8086` for database inspection (optional)

### Manual PostgreSQL Setup

If you prefer using your own PostgreSQL:

1. Ensure PostgreSQL is running locally
2. Update database config in `config/config.exs` if needed
3. Install dependencies: `mix deps.get`
4. Setup test database: `MIX_ENV=test mix ecto.setup`
5. Run tests: `mix test`

### Development Commands

```bash
# Setup test database (first time or reset)
MIX_ENV=test mix ecto.setup

# Run tests
mix test

# Reset database and run fresh migration
MIX_ENV=test mix ecto.reset

# Format code
mix format

# Type checking
mix dialyzer

# Generate documentation
mix docs

# Run all checks (format + dialyzer)
mix lint
```

## Database Support

Right now, Sifter is PostgreSQL-only. Why? Because PostgreSQL is what we use in production, and it has fantastic full-text search capabilities that we leverage heavily. The library does advanced stuff with tsvector, tsquery, and GIN indexes that simply don't exist in other databases.

Could we support MySQL, SQLite, or others? Probably! But it's going to take some work to get 100% API compatibility, and I'd need help from folks who use those databases in production. If you're interested in contributing support for another database, please reach out!

## Query Syntax

Your frontend developers will love this:

```javascript
// Simple field filtering
"status:active priority:>3"

// Boolean logic
"status:draft OR status:review"
"(urgent OR critical) AND assignedTo:john"

// Lists and wildcards
"tag IN (backend, api) title:bug*"

// Full-text search (unqualified terms)
"machine learning algorithms"

// Mix it all together
"elixir phoenix status:published OR (draft author:me) createdAt:>=2024-01-01"
```

## Contributing

This library is young and hungry for improvements! We welcome all sorts of contributions:

- 📝 **Documentation**: Found a typo? Example not clear? PRs welcome!
- 🐛 **Bug fixes**: Something broken? Let's fix it together
- ⚡ **Performance**: Got ideas for faster queries? Yes please!
- 💡 **Use cases**: Share how you're using Sifter in your apps
- 🔧 **Features**: Have ideas? Open an issue and let's discuss

Check out the [contributing guide](CONTRIBUTING.md) for more details.

## Documentation

- [Overview](guides/overview.md) - Understand what Sifter does
- [Getting Started](guides/getting-started.md) - Your first queries
- [Query Syntax](guides/query-syntax.md) - Complete syntax reference
- [Configuration](guides/configuration.md) - All configuration options
- [Full-Text Search](guides/full-text-search.md) - PostgreSQL search setup
- [Integration Patterns](guides/integration-patterns.md) - Examples
- [Error Handling](guides/error-handling.md) - Handle errors gracefully

## License

MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by Shopify's search syntax in their REST APIs
- Built on top of the excellent Ecto library
- Thanks to the Elixir community for being awesome

---

Built with ❤️ for the Elixir community. If you find this useful, give it a star! ⭐
