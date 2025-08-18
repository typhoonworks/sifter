# Error Handling

This guide provides comprehensive information about Sifter's error handling, including all error types, their causes, and how to handle them in your applications.

## Error Structure

Sifter errors are structured exceptions with three main components:

```elixir
%Sifter.Error{
  stage: :lex | :parse | :build,  # Which stage failed
  reason: term(),                 # Specific error details
  token: term()                   # Optional token information
}
```

## Error Stages

Sifter processes queries in three stages, each with its own error types:

1. **Lexing Stage (`:lex`)** - Tokenizing the input string
2. **Parsing Stage (`:parse`)** - Converting tokens to AST
3. **Building Stage (`:build`)** - Converting AST to Ecto queries

## Lexing Errors (`:lex`)

### Unterminated String

**Cause**: String quotes not properly closed

```elixir
# Error examples
"title:'unterminated string"
"author:\"missing quote"

# Error details
%Sifter.Error{
  stage: :lex,
  reason: {:unterminated_string, nil, {offset, length}}
}

# Message: "Unterminated string at position 7. Strings must be closed with a matching quote."
```

**Fix**: Ensure all quoted strings have matching opening and closing quotes.

### Invalid Comparator

**Cause**: Using unsupported comparison operators

```elixir
# Error examples  
"priority=5"        # Use : for equality
"status:=published" # Invalid combination

# Error details
%Sifter.Error{
  stage: :lex,
  reason: {:invalid_comparator, "=", {offset, length}}
}

# Message: "Invalid operator '=' at position 8. Use ':' for equality or '>', '<', '>=', '<=' for comparisons."
```

**Fix**: Use `:` for equality or `>`, `<`, `>=`, `<=` for comparisons.

### Unexpected Character

**Cause**: Characters that can't be tokenized in their context

```elixir
# Error examples
"created_at>=2024-01-01T10:30:00Z"  # Colon in unquoted ISO datetime
"field@value"                       # @ symbol not supported

# Error details  
%Sifter.Error{
  stage: :lex,
  reason: {:unexpected_char, ":", {offset, length}}
}

# Message: "Unexpected character ':' at position 25."
```

**Fix**: Quote values containing special characters: `createdAt>='2024-01-01T10:30:00Z'`

### Invalid Field Name

**Cause**: Field names that don't follow naming rules

```elixir
# Error examples
"123field:value"    # Cannot start with number
"field.:value"      # Cannot end with dot

# Error details
%Sifter.Error{
  stage: :lex, 
  reason: {:invalid_field, "123field", {offset, length}}
}

# Message: "Invalid field name '123field' at position 0. Field names must start with a letter or underscore."
```

**Fix**: Ensure field names start with letter or underscore: `_field:value` or `field123:value`

## Parsing Errors (`:parse`)

### Unexpected Token

**Cause**: Tokens that don't fit the grammar in their position

```elixir
# Error examples
"OR status:published"    # Cannot start with OR
"status: AND priority>5" # Missing value after :

# Error details
%Sifter.Error{
  stage: :parse,
  reason: {:unexpected_token, {:OR_CONNECTOR, "OR", "or", {0, 2}}}
}

# Message: "Unexpected token 'OR' at position 0."
```

**Fix**: Ensure proper query structure with complete predicates.

### Unexpected EOF After Operator

**Cause**: Operators without following expressions

```elixir
# Error examples  
"status:published AND"   # AND with no right side
"priority>"             # > with no value

# Error details
%Sifter.Error{
  stage: :parse,
  reason: {:unexpected_eof_after_operator, {:AND_CONNECTOR, "AND", "and", {18, 3}}}
}

# Message: "Expected expression after 'AND' at position 18. Operators must be followed by a value or field."
```

**Fix**: Complete all expressions: `status:published AND priority>5`

### Missing Right Parenthesis

**Cause**: Unmatched opening parentheses

```elixir
# Error examples
"(status:draft OR status:review"    # Missing closing )
"((priority>5) AND status:live"     # Missing one closing )

# Error details
%Sifter.Error{
  stage: :parse,
  reason: {:missing_right_paren, {:LEFT_PAREN, "(", nil, {0, 1}}}
}

# Message: "Missing closing parenthesis ')' for opening parenthesis at position 0."
```

**Fix**: Match every opening parenthesis with a closing one: `(status:draft OR status:review)`

### Empty List

**Cause**: Lists without any values

```elixir
# Error examples
"status IN ()"           # Empty parentheses
"category NOT IN (  )"   # Whitespace only

# Error details
%Sifter.Error{
  stage: :parse,
  reason: {:empty_list, {:LEFT_PAREN, "(", nil, {10, 1}}}
}

# Message: "Empty list at position 10. Lists must contain at least one value."
```

**Fix**: Include at least one value: `status IN (draft, published)`

### Trailing Comma in List

**Cause**: Extra comma after last list item

```elixir
# Error examples
"status IN (draft, published,)"     # Trailing comma
"priority IN (1, 2, 3, )"          # Space before trailing comma

# Error details
%Sifter.Error{
  stage: :parse,
  reason: {:trailing_comma_in_list, {:COMMA, ",", nil, {25, 1}}}
}

# Message: "Trailing comma at position 25. Remove the comma after the last list item."
```

**Fix**: Remove trailing comma: `status IN (draft, published)`

### Invalid Wildcard Position

**Cause**: Wildcards in unsupported positions

```elixir
# Error examples  
"title:prefix*suffix"    # Middle wildcard
"title:pre*fix*"        # Multiple wildcards

# Error details
%Sifter.Error{
  stage: :parse,
  reason: {:invalid_wildcard_position, {:STRING_VALUE, "pre*fix*", "pre*fix*", {6, 8}}}
}

# Message: "Invalid wildcard pattern 'pre*fix*' at position 6. Use 'field:prefix*' or 'field:*suffix', not middle wildcards."
```

**Fix**: Use only prefix or suffix wildcards: `title:prefix*` or `title:*suffix`

### Empty Group

**Cause**: Empty parentheses in expressions

```elixir
# Error examples
"status:published AND ()"        # Empty parentheses
"() OR priority>5"               # Empty group at start

# Error details  
%Sifter.Error{
  stage: :parse,
  reason: {:empty_group, {:LEFT_PAREN, "(", nil, {22, 1}}}
}

# Message: "Empty parentheses at position 22. Parentheses must contain an expression."
```

**Fix**: Include expressions within parentheses: `status:published AND (priority>5)`

## Building Errors (`:build`)

### Unknown Field

**Cause**: Fields not in the allow-list or schema

```elixir
# Using strict mode or explicit error handling
{:error, error} = Sifter.filter(Post, "unknownField:value",
  schema: Post, 
  allowed_fields: ["status"], 
  unknown_field: :error
)

# Error details
%Sifter.Error{
  stage: :build,
  reason: {:builder, {:unknown_field, "unknownField"}}
}
```

**Fix**: Add field to allow-list or fix field name spelling.

### Type Casting Errors

**Cause**: Values that can't be cast to the field's Ecto type

```elixir
# Examples that cause casting errors
"priority:not_a_number"     # String to integer field
"created_at:invalid_date"   # Invalid date format

# These errors depend on configuration:
# - :ignore - Skip the predicate
# - :warn - Add warning to metadata  
# - :error - Return error
```

**Fix**: Provide values in correct format for the field type.

## Error Handling Strategies

### Per-Call Error Handling

```elixir
case Sifter.filter(Post, query_string, schema: Post) do
  {:ok, query, meta} ->
    # Handle successful parsing
    posts = Repo.all(query)
    render(conn, "index.html", posts: posts)
    
  {:error, %Sifter.Error{stage: :lex} = error} ->
    # Lexing error - invalid syntax
    Logger.warn("Lexing error: #{Exception.message(error)}")
    render(conn, "error.html", message: "Invalid search syntax")
    
  {:error, %Sifter.Error{stage: :parse} = error} ->
    # Parsing error - malformed query
    Logger.warn("Parsing error: #{Exception.message(error)}")
    render(conn, "error.html", message: "Malformed search query")
    
  {:error, %Sifter.Error{stage: :build} = error} ->
    # Building error - schema/field issues
    Logger.warn("Building error: #{Exception.message(error)}")
    render(conn, "error.html", message: "Invalid field in search")
end
```

### Graceful Degradation

```elixir
defmodule MyApp.SearchHelpers do
  def safe_search(schema, query_string, opts \\ []) do
    try do
      Sifter.filter!(schema, query_string, opts)
    rescue
      Sifter.Error ->
        # Fall back to unfiltered query
        {schema, %{uses_full_text?: false, warnings: []}}
    end
  end
  
  def safe_search_with_fallback(schema, query_string, opts \\ []) do
    case Sifter.filter(schema, query_string, opts) do
      {:ok, query, meta} ->
        {:ok, query, meta}
        
      {:error, %Sifter.Error{stage: stage}} when stage in [:lex, :parse] ->
        # Syntax errors - return empty results
        empty_query = from(r in schema, where: false)
        {:ok, empty_query, %{uses_full_text?: false, warnings: []}}
        
      {:error, %Sifter.Error{stage: :build}} ->
        # Field errors - return unfiltered results
        {:ok, schema, %{uses_full_text?: false, warnings: []}}
    end
  end
end
```

### User-Friendly Error Messages

```elixir
defmodule MyApp.ErrorMessages do
  def user_friendly_message(%Sifter.Error{stage: :lex, reason: reason}) do
    case reason do
      {:unterminated_string, _, _} ->
        "Please close your quoted text with matching quotes."
        
      {:invalid_comparator, "=", _} ->
        "Use ':' for equals. Example: status:published"
        
      {:unexpected_char, char, _} when char in [":", "T"] ->
        "Please quote date/time values. Example: createdAt:'2024-01-01T10:00:00Z'"
        
      _ ->
        "Invalid search syntax. Please check your query."
    end
  end
  
  def user_friendly_message(%Sifter.Error{stage: :parse, reason: reason}) do
    case reason do
      {:unexpected_token, _} ->
        "Unexpected word or symbol in your search query."
        
      {:missing_right_paren, _} ->
        "Please close all parentheses in your query."
        
      {:empty_list, _} ->
        "Lists must contain at least one item. Example: status IN (draft, published)"
        
      {:trailing_comma_in_list, _} ->
        "Remove the extra comma at the end of your list."
        
      _ ->
        "Invalid search query structure."
    end
  end
  
  def user_friendly_message(%Sifter.Error{stage: :build}) do
    "One or more fields in your search are not available."
  end
end
```

### Development vs Production Error Handling

```elixir
# config/dev.exs
config :my_app, :sifter_error_handling, :detailed

# config/prod.exs  
config :my_app, :sifter_error_handling, :user_friendly

# In your controller
def handle_sifter_error(error) do
  case Application.get_env(:my_app, :sifter_error_handling, :user_friendly) do
    :detailed ->
      # Show full error details in development
      Exception.message(error)
      
    :user_friendly ->
      # Show simplified message in production
      MyApp.ErrorMessages.user_friendly_message(error)
  end
end
```

## Configuration-Based Error Handling

### Unknown Field Handling

```elixir
# Ignore unknown fields (default)
{query, meta} = Sifter.filter!(Post, "status:published invalidField:test",
  schema: Post,
  allowed_fields: ["status"],
  unknown_field: :ignore
)
# Result: Filters only by status, ignores invalidField

# Warn about unknown fields
{query, meta} = Sifter.filter!(Post, "status:published invalidField:test", 
  schema: Post,
  allowed_fields: ["status"],
  unknown_field: :warn
)
# Result: Filters by status, meta.warnings contains info about invalidField

# Error on unknown fields
{:error, error} = Sifter.filter(Post, "status:published invalidField:test",
  schema: Post, 
  allowed_fields: ["status"],
  unknown_field: :error
)
# Result: Returns error immediately
```

### Mode-Based Configuration

```elixir
# Lenient mode - ignore most issues
{query, meta} = Sifter.filter!(Post, "status:published invalidField:test",
  schema: Post,
  mode: :lenient
)

# Strict mode - error on any issues
{:error, error} = Sifter.filter(Post, "status:published invalidField:test",
  schema: Post,
  mode: :strict
)
```

This comprehensive error handling guide covers all the error types you'll encounter when using Sifter and provides practical strategies for handling them in your applications.