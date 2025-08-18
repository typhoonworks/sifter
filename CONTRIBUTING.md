# Contributing to Sifter

Thank you for your interest in contributing to Sifter! 🎉

We welcome contributions of all kinds - whether you're fixing a typo, reporting a bug, proposing a new feature, or improving documentation. This guide will help you get started.

## Code of Conduct

By participating in this project, you agree to be respectful and constructive in your interactions with other contributors and maintainers.

## Getting Started

### Development Setup

1. **Fork and clone the repository**
   ```bash
   git clone https://github.com/yourusername/sifter.git
   cd sifter
   ```

2. **Start PostgreSQL with Docker**
   ```bash
   docker compose up -d
   ```

3. **Install dependencies**
   ```bash
   mix deps.get
   ```

4. **Run the tests** (migrations run automatically)
   ```bash
   mix test
   ```

5. **Check code quality**
   ```bash
   mix format --check-formatted
   mix dialyzer
   ```

### Development Workflow

- Create a feature branch from `main`
- Make your changes
- Add or update tests as needed
- Ensure all tests pass
- Run formatting and Dialyzer checks
- Submit a pull request

## Types of Contributions

### 🐛 Bug Reports

When reporting bugs, please include:

- A clear description of the issue
- Steps to reproduce the problem
- Expected vs actual behavior
- Your Elixir/Erlang/PostgreSQL versions
- Any relevant error messages or logs

### 💡 Feature Requests

For new features:

- Open an issue first to discuss the idea
- Explain the use case and why it would be valuable
- Consider if it fits with Sifter's goals and philosophy
- Be open to feedback and alternative approaches

### 📝 Documentation

Documentation improvements are always welcome:

- Fix typos or unclear explanations
- Add examples for common use cases
- Improve code comments
- Update guides when features change

### 🔧 Code Contributions

#### Pull Request Process

1. **Fork the repository** and create a feature branch
2. **Write tests** for any new functionality
3. **Update documentation** if your changes affect the public API
4. **Follow the coding standards** (see below)
5. **Ensure CI passes** - all tests, formatting, and Dialyzer checks
6. **Write a clear commit message** explaining your changes

#### Coding Standards

- **Follow existing patterns** in the codebase
- **Write comprehensive tests** for new functionality
- **Add documentation** for public functions using `@doc`
- **Use descriptive variable and function names**
- **Keep functions focused** and single-purpose
- **Follow Elixir naming conventions**

#### Testing Guidelines

- Write tests for both happy path and error cases
- Use descriptive test names that explain what's being tested
- Group related tests using `describe` blocks
- Test edge cases and boundary conditions
- Ensure tests are deterministic and don't depend on external state

## Project Structure

```
├── lib/
│   ├── sifter.ex              # Main public API
│   └── sifter/
│       ├── query/             # Query parsing and lexing
│       ├── ecto/              # Ecto integration
│       └── full_text/         # Full-text search features
├── test/
│   ├── support/               # Test helpers and fixtures
│   └── sifter/                # Test files mirroring lib structure
├── guides/                    # Documentation guides
└── .github/
    └── workflows/             # CI configuration
```

## Release Process

Maintainers handle releases, but contributors should:

- Keep the CHANGELOG.md updated with notable changes
- Follow semantic versioning principles
- Update documentation for breaking changes

## Getting Help

- **Questions about usage**: Open a GitHub issue with the "question" label
- **Contributing questions**: Feel free to ask in an issue or pull request
- **Bug reports**: Use the issue tracker

## Recognition

All contributors will be recognized in our release notes and documentation. Thank you for helping make Sifter better! 

## What We're Looking For

We're especially interested in:

- **Real-world use cases** and feedback
- **Performance improvements** and optimizations
- **Additional database support** (MySQL, SQLite, etc.)
- **Better error messages** and debugging experience
- **Integration examples** with popular frameworks
- **Security reviews** and improvements

---

Thanks for contributing to Sifter! Your time and effort help make this library better for the entire Elixir community. 🚀