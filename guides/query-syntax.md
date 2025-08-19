# Query Syntax

Sifter provides a comprehensive query language for filtering data. This guide covers all supported syntax features with detailed examples.

## Grammar Overview

Sifter queries are composed of terms separated by whitespace, with support for:

- **Field predicates**: `field:value`, `field>10`, `field IN (a, b)`
- **Boolean logic**: `AND`, `OR`, `NOT`, `-` (negation)
- **Grouping**: Parentheses for precedence control
- **Wildcards**: Prefix/suffix matching with `*`
- **Full-text search**: Bare terms for text search across fields

## Basic Syntax Rules

### Whitespace and Implicit AND

Terms separated by whitespace are joined with implicit AND:

```
status:published priority>3
# Equivalent to: status:published AND priority>3
```

### Case Sensitivity

- **Field names**: Case-sensitive (`status` ≠ `Status`)
- **Keywords**: Case-insensitive (`AND` = `and` = `And`)
- **Values**: Case-sensitive (`published` ≠ `Published`)

### Automatic Field Name Conversion

Sifter automatically converts camelCase field names to snake_case:

```
createdAt>='2024-01-01'    # Becomes: created_at >= '2024-01-01'
authorId:123               # Becomes: author_id = 123
```

## Field-Based Predicates

### Equality (`:`)

Match exact field values:

```
status:published
category:tech
author_id:123
organization_id:NULL     # Match records where organization_id is NULL
```

### Comparison Operators

Compare numeric, date, and other ordered values:

```
# Greater than
priority>5
createdAt>'2024-01-01'

# Greater than or equal
rating>=4.0
updatedAt>='2024-01-01T10:00:00Z'

# Less than
views<1000
expiresAt<'2024-12-31'

# Less than or equal
price<=99.99
publishedAt<='2024-01-01'
```

### Set Operations

Test membership in a list of values:

```
# IN - match any value in the list
status IN (draft, published, review)
category IN (tech, science)

# IN with NULL - match NULL or specific values
organization_id IN (NULL, 123, 456)

# NOT IN - exclude any value in the list
status NOT IN (archived, deleted)
priority NOT IN (1, 2)

# NOT IN with NULL - exclude NULL and specific values
priority NOT IN (NULL, 0)
```

**Notes on Lists**:
- Must be enclosed in parentheses
- Values separated by commas
- Whitespace around commas is optional: `(a,b,c)` = `(a, b, c)`
- Empty lists are not allowed
- Trailing commas are not allowed

## String Quoting and When Values Must Be Quoted

### Values That MUST Be Quoted

**ISO datetime values with time components:**
```
# ✓ Correct - quoted
createdAt>='2024-01-01T10:30:00Z'
updatedAt<='2021-11-11T12:33:15.661Z'

# ✗ Invalid - unquoted (lexer confused by colons)
createdAt>=2024-01-01T10:30:00Z
```

**Negative numbers:**
```
# ✓ Correct - quoted (avoids confusion with NOT modifier)
temperature>='-5.2'
balance>'-100'

# ✗ Potentially problematic - unquoted
temperature>=-5.2    # Dash might be interpreted as NOT
```

**Values with spaces or special characters:**
```
# ✓ Required - quoted
title:"Introduction to Elixir"
description:"A comprehensive guide"
filename:"report(final).pdf"
path:"/var/log/app.log"

# In lists too
category IN ('high priority', 'urgent-fix', 'archived/deleted')

# ✗ Invalid - unquoted
title:Introduction to Elixir    # Spaces break parsing
```

### When Quoting Is Optional

Simple values without special characters can be unquoted:

**Simple field values:**
```
# Both are equivalent
status:published      # ✓ Unquoted works fine
status:'published'    # ✓ Quoted also works

# Simple numbers
priority:5           # ✓ Unquoted works
priority:'5'         # ✓ Quoted also works
```

**Simple dates (no time component):**
```
createdAt>2024-01-01  # ✓ Unquoted works
createdAt>'2024-01-01' # ✓ Quoted also works
```

**Simple values in lists:**
```
# Both work fine for simple values
status IN (draft, published, review)        # ✓ Unquoted
status IN ('draft', 'published', 'review')  # ✓ Quoted

# Mixed quoting is allowed
status IN (draft, 'in progress', archived)  # ✓ Mixed
```

**Floating point numbers:**
```
# Usually work unquoted, but quoting is safer
price>=3.14          # ✓ Usually works
price>='3.14'        # ✓ Safer (avoids potential dot confusion)
rating<=4.5          # ✓ Usually works
rating<='4.5'        # ✓ Safer
```

### Best Practice: When In Doubt, Quote

**Recommendation**: Quote your values when uncertain. Quoted values are always safe and unambiguous.

```
# Safe approach - quote problematic values
price>='-5.2'
createdAt>='2024-01-01T10:30:00Z'
rating<='4.5'
category IN ('high priority', urgent, archived)
```

### Special Characters

Characters requiring quotes in values:
- Whitespace: ` `, `\t`, `\r`, `\n`
- Operators: `:`, `<`, `>`, `=`
- Grouping: `(`, `)`, `,`
- Quotes: `'`, `"`
- Time separators in ISO dates: `T`, `:`

## Wildcards

Wildcards work only with the equality operator (`:`) and support prefix/suffix matching:

### Prefix Matching

Find values starting with a pattern:

```
title:Introduction*      # Titles starting with "Introduction"
author.name:John*       # Authors whose names start with "John"
category:tech*          # Categories starting with "tech"
```

### Suffix Matching

Find values ending with a pattern:

```
title:*Guide            # Titles ending with "Guide"
email:*@company.com     # Emails ending with "@company.com"
filename:*.pdf          # Filenames ending with ".pdf"
```

### Wildcard Restrictions

- **Only with equality**: `title:prefix*` ✓, `title>prefix*` ✗
- **No middle wildcards**: `title:*middle*` ✗
- **Must quote if literal**: `title:"*literal*"` for actual asterisks
- **Not allowed unquoted in lists**: `category IN (tech*)` ✗, `category IN ('tech*')` ✓

## Boolean Logic

### AND Operator

Explicit AND (higher precedence than OR):

```
status:published AND priority>3
(status:draft OR status:review) AND priority>5
```

### OR Operator

Combine alternative conditions (lower precedence than AND):

```
status:draft OR status:review
category:tech OR category:science OR category:elixir
```

### Operator Precedence

AND binds tighter than OR:

```
# This query:
status:draft OR status:review AND priority>3

# Is equivalent to:
status:draft OR (status:review AND priority>3)

# Use parentheses for different precedence:
(status:draft OR status:review) AND priority>3
```

### NOT Operator

Negate field-based predicates and groups:

```
# NOT keyword with field predicates
NOT status:archived
NOT (status:draft OR status:spam)

# Shorthand with dash (no space after)
-status:archived
-(priority>5 AND category:urgent)
```

**Important**: NOT works with field predicates, but you cannot negate full-text search terms directly:

```
# ✓ Works - negating field predicates
NOT status:spam
-category:archived
status:published AND NOT priority<3

# ✗ Does not work - negating full-text search
NOT spam              # Results in {:no_predicates, query}
status:published AND NOT urgent  # Full-text 'urgent' cannot be negated
```

## Grouping with Parentheses

Use parentheses to control evaluation order:

```
# Simple grouping
(status:draft OR status:review) AND priority>3

# Nested grouping
(status:published AND priority>5) OR (status:featured AND views>1000)

# Complex expressions
((status:draft OR status:review) AND priority>3) OR category:urgent
```

## Association Fields

Access related data using dot notation:

### Belongs To / Has One

Single related records:

```
author.name:john
organization.tier:premium
project.status:active
```

### Has Many / Many To Many

Multiple related records (automatically applies DISTINCT):

```
tags.name:elixir
comments.status:approved
categories.slug:tech
```

### Nested Associations

Currently limited to one level:

```
author.organization:acme     # ✓ Supported
author.org.name:acme        # ✗ Not supported (>1 level)
```

## Full-Text Search

Bare terms (not in field:value format) perform full-text search across configured fields:

### Simple Terms

```
elixir              # Search for "elixir" in configured text fields
"machine learning"  # Phrase search (exact match)
```

### Mixed Field and Full-Text

Combine field filters with text search:

```
status:published elixir           # Published posts containing "elixir"
priority>3 "machine learning"     # High priority posts about "machine learning"
```

### Quoted vs Unquoted

- **Unquoted**: `machine learning` → searches for documents containing both words
- **Quoted**: `"machine learning"` → searches for the exact phrase

### Full-Text Search Limitations

Full-text search terms cannot be negated directly:

```
# ✓ Works - field filtering with full-text
status:published machine learning
category:tech AND elixir

# ✗ Does not work - negating full-text terms
NOT machine learning    # Results in {:no_predicates, query}
-elixir                # Cannot negate full-text search
```

## Field Names and Paths

### Valid Field Names

Field names must:
- Start with letter or underscore: `name`, `_private`
- Contain letters, numbers, underscores, hyphens: `field_name`, `field-name`
- Support dot notation for associations: `author.name`

### Invalid Field Names

```
123field        # Cannot start with number
field.          # Cannot end with dot
field..name     # Cannot have consecutive dots
field.123       # Association part cannot start with number
```

## Complete Example Queries

### E-commerce Product Search

```
# Complex product filtering
(category:electronics OR category:computers)
AND price<=500
AND rating>=4.0
AND NOT discontinued:true
AND brand IN (apple, samsung, sony)
```

### Blog Post Management

```
# Editorial workflow
(status:draft OR status:review)
AND author.role:editor
AND createdAt>='2024-01-01'
AND tags.name:featured
AND NOT status:spam
```

### User Analytics

```
# Active user analysis
lastLoginAt>'2024-01-01'
AND subscriptionStatus:active
AND organization.tier IN (premium, enterprise)
AND NOT role:guest
```

### Time-based Filtering

```
# Date range with proper quoting for ISO datetimes
createdAt>='2024-01-01T00:00:00Z'
AND createdAt<='2024-12-31T23:59:59Z'
AND status:published
```

### Content Search with Mixed Conditions

```
# Content filtering with full-text search
status:published
AND category IN (tech, science)
AND NOT tags.name:archived
AND machine learning    # Full-text search
```

## Error Cases

### Syntax Errors

```
# Invalid operators
field:>value        # ✗ Cannot combine : with >
field IN value      # ✗ IN requires parentheses

# Malformed groups
(field:value        # ✗ Missing closing paren
field:value)        # ✗ Missing opening paren
()                  # ✗ Empty groups not allowed

# Invalid lists
field IN ()         # ✗ Empty lists not allowed
field IN (a,)       # ✗ Trailing commas not allowed
field IN (a b)      # ✗ Missing comma between values

# Unquoted problematic values
createdAt>=2024-01-01T10:30:00Z  # ✗ ISO datetime needs quotes
temperature>=-5.2                # ✗ Negative numbers should be quoted
title:Introduction to Elixir     # ✗ Spaces need quotes
```

### Semantic Errors

```
# Wildcards in wrong context
field>prefix*       # ✗ Wildcards only work with :
field IN (prefix*)  # ✗ Wildcards not allowed unquoted in lists

# Invalid field paths
field...name        # ✗ Empty path segments
field.              # ✗ Trailing dot
.field             # ✗ Leading dot

# Negating full-text search
NOT machine learning  # ✗ Results in {:no_predicates, query}
-urgent              # ✗ Cannot negate full-text terms
```

## Best Practices

### Quote Values Strategically

```
# Quote when needed for clarity and safety
price>='-5.2'                    # Negative numbers
createdAt>='2024-01-01T10:30:00Z' # ISO datetimes
title:"Introduction to Elixir"   # Values with spaces
category IN ('high priority', urgent, 'auto-generated')  # Mix as needed

# Simple values can remain unquoted
status:active
priority:5
category IN (tech, science, elixir)
```

### Use Appropriate Operators

```
# Good - semantic operators
priority>5             # Numeric comparison
status:active          # Exact match
createdAt>='2024-01-01' # Date comparison

# Avoid - unclear intent
priority:>5            # Invalid syntax
status>"active"        # Unnecessary comparison for equality
```

### Understand NOT Limitations

```
# Good - negating field predicates
NOT status:archived
-category:spam
(status:draft OR status:review) AND NOT priority<2

# Avoid - trying to negate full-text search
NOT urgent             # Won't work as expected
status:active AND NOT "machine learning"  # Full-text negation fails
```

### Use Consistent Field Names

```
# Good - consistent naming
createdAt>='2024-01-01'   # camelCase (converted automatically)
created_at>='2024-01-01'  # snake_case (used directly)

# Avoid - mixing conventions inconsistently within same query
createdAt>='2024-01-01' AND updated_at<='2024-12-31'
```

This syntax provides a balance of power and simplicity, allowing complex queries while remaining intuitive for end users. Remember: **quote values when they contain special characters** and **NOT only works with field predicates, not full-text search terms**.
