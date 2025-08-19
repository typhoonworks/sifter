defmodule Sifter.Query.LexerTest do
  use ExUnit.Case, async: true
  alias Sifter.Query.Lexer

  describe "single and bare terms" do
    test "empty string" do
      assert Lexer.tokenize("") ==
               {:ok,
                [
                  {:EOF, "", nil, {0, 0}}
                ]}
    end

    test "single bare term" do
      assert Lexer.tokenize("Jane") ==
               {:ok,
                [
                  {:STRING_VALUE, "Jane", "Jane", {0, 4}},
                  {:EOF, "", nil, {4, 0}}
                ]}
    end

    test "multiple unquoted words with implied AND" do
      assert Lexer.tokenize("Jane Doe") ==
               {:ok,
                [
                  {:STRING_VALUE, "Jane", "Jane", {0, 4}},
                  {:AND_CONNECTOR, " ", "and", {4, 1}},
                  {:STRING_VALUE, "Doe", "Doe", {5, 3}},
                  {:EOF, "", nil, {8, 0}}
                ]}
    end

    test "no trailing AND after trailing spaces" do
      assert Lexer.tokenize("Jane   ") ==
               {:ok,
                [
                  {:STRING_VALUE, "Jane", "Jane", {0, 4}},
                  {:EOF, "", nil, {7, 0}}
                ]}
    end

    test "leading space does not create AND" do
      assert Lexer.tokenize(" Jane Doe") ==
               {:ok,
                [
                  {:STRING_VALUE, "Jane", "Jane", {1, 4}},
                  {:AND_CONNECTOR, " ", "and", {5, 1}},
                  {:STRING_VALUE, "Doe", "Doe", {6, 3}},
                  {:EOF, "", nil, {9, 0}}
                ]}
    end

    test "single quoted term (single quotes)" do
      assert Lexer.tokenize("'Jane Doe'") ==
               {:ok,
                [
                  {:STRING_VALUE, "'Jane Doe'", "Jane Doe", {0, 10}},
                  {:EOF, "", nil, {10, 0}}
                ]}
    end

    test "single quoted term (double quotes)" do
      assert Lexer.tokenize("\"Jane Doe\"") ==
               {:ok,
                [
                  {:STRING_VALUE, "\"Jane Doe\"", "Jane Doe", {0, 10}},
                  {:EOF, "", nil, {10, 0}}
                ]}
    end

    test "escaped quote inside single quotes" do
      assert Lexer.tokenize("'O\\'Connor'") ==
               {:ok,
                [
                  {:STRING_VALUE, "'O\\'Connor'", "O'Connor", {0, 11}},
                  {:EOF, "", nil, {11, 0}}
                ]}
    end
  end

  describe "equality comparator terms" do
    test "field in snake_case" do
      assert Lexer.tokenize("first_name:Jane") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "first_name", "first_name", {0, 10}},
                  {:EQUALITY_COMPARATOR, ":", nil, {10, 1}},
                  {:STRING_VALUE, "Jane", "Jane", {11, 4}},
                  {:EOF, "", nil, {15, 0}}
                ]}
    end

    test "field in camelCase → snake_case literal" do
      assert Lexer.tokenize("firstName:Jane") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "firstName", "first_name", {0, 9}},
                  {:EQUALITY_COMPARATOR, ":", nil, {9, 1}},
                  {:STRING_VALUE, "Jane", "Jane", {10, 4}},
                  {:EOF, "", nil, {14, 0}}
                ]}
    end

    test "quoted value" do
      assert Lexer.tokenize("name:'Jane Doe'") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "name", "name", {0, 4}},
                  {:EQUALITY_COMPARATOR, ":", nil, {4, 1}},
                  {:STRING_VALUE, "'Jane Doe'", "Jane Doe", {5, 10}},
                  {:EOF, "", nil, {15, 0}}
                ]}
    end

    test "dot-notation field" do
      assert Lexer.tokenize("user.first_name:Jane") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "user.first_name", "user.first_name", {0, 15}},
                  {:EQUALITY_COMPARATOR, ":", nil, {15, 1}},
                  {:STRING_VALUE, "Jane", "Jane", {16, 4}},
                  {:EOF, "", nil, {20, 0}}
                ]}
    end

    test "camelCase dot-notation → snake_case literal per segment" do
      assert Lexer.tokenize("userProfile.firstName:Jane") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "userProfile.firstName", "user_profile.first_name",
                   {0, 21}},
                  {:EQUALITY_COMPARATOR, ":", nil, {21, 1}},
                  {:STRING_VALUE, "Jane", "Jane", {22, 4}},
                  {:EOF, "", nil, {26, 0}}
                ]}
    end

    test "split operator is invalid ('< =')" do
      assert Lexer.tokenize("count:< =10") ==
               {:error, {:broken_operator, "< =", {7, 2}}}
    end

    test "no implied AND within a predicate boundary" do
      assert Lexer.tokenize("name:  Jane") ==
               {:error, {:invalid_predicate_spacing, nil, {5, 1}}}
    end
  end

  describe "lesser than or equal to comparator terms" do
    test "field in snake_case" do
      assert Lexer.tokenize("max_price<=10") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "max_price", "max_price", {0, 9}},
                  {:LESS_THAN_OR_EQUAL_TO_COMPARATOR, "<=", nil, {9, 2}},
                  {:STRING_VALUE, "10", "10", {11, 2}},
                  {:EOF, "", nil, {13, 0}}
                ]}
    end

    test "field in camelCase → snake_case literal" do
      assert Lexer.tokenize("maxPrice<=10") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "maxPrice", "max_price", {0, 8}},
                  {:LESS_THAN_OR_EQUAL_TO_COMPARATOR, "<=", nil, {8, 2}},
                  {:STRING_VALUE, "10", "10", {10, 2}},
                  {:EOF, "", nil, {12, 0}}
                ]}
    end

    test "quoted value" do
      assert Lexer.tokenize("created_at<='2021-11-11'") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "created_at", "created_at", {0, 10}},
                  {:LESS_THAN_OR_EQUAL_TO_COMPARATOR, "<=", nil, {10, 2}},
                  {:STRING_VALUE, "'2021-11-11'", "2021-11-11", {12, 12}},
                  {:EOF, "", nil, {24, 0}}
                ]}
    end

    test "doth paths" do
      assert Lexer.tokenize("order.total<=100") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "order.total", "order.total", {0, 11}},
                  {:LESS_THAN_OR_EQUAL_TO_COMPARATOR, "<=", nil, {11, 2}},
                  {:STRING_VALUE, "100", "100", {13, 3}},
                  {:EOF, "", nil, {16, 0}}
                ]}
    end

    test "camelCase doth paths" do
      assert Lexer.tokenize("orderTotals.grandTotal<=100") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "orderTotals.grandTotal", "order_totals.grand_total",
                   {0, 22}},
                  {:LESS_THAN_OR_EQUAL_TO_COMPARATOR, "<=", nil, {22, 2}},
                  {:STRING_VALUE, "100", "100", {24, 3}},
                  {:EOF, "", nil, {27, 0}}
                ]}
    end

    test "missing value" do
      assert Lexer.tokenize("price<=") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "price", "price", {0, 5}},
                  {:LESS_THAN_OR_EQUAL_TO_COMPARATOR, "<=", nil, {5, 2}},
                  {:EOF, "", nil, {7, 0}}
                ]}
    end

    test "unquoted ISO date-time is invalid; require quotes" do
      assert Lexer.tokenize("created_at<=2021-11-11T10:30:00Z") ==
               {:error, {:unexpected_char, ":", {25, 1}}}
    end

    test "space between field and '<=' is invalid" do
      assert Lexer.tokenize("price <=10") ==
               {:error, {:invalid_predicate_spacing, nil, {5, 1}}}
    end

    test "space between '<=' and value is invalid" do
      assert Lexer.tokenize("price<= 10") ==
               {:error, {:invalid_predicate_spacing, nil, {7, 1}}}
    end
  end

  describe "lesser than comparator terms" do
    test "field in snake_case" do
      assert Lexer.tokenize("max_price<10") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "max_price", "max_price", {0, 9}},
                  {:LESS_THAN_COMPARATOR, "<", nil, {9, 1}},
                  {:STRING_VALUE, "10", "10", {10, 2}},
                  {:EOF, "", nil, {12, 0}}
                ]}
    end

    test "field in camelCase → snake_case literal" do
      assert Lexer.tokenize("maxPrice<10") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "maxPrice", "max_price", {0, 8}},
                  {:LESS_THAN_COMPARATOR, "<", nil, {8, 1}},
                  {:STRING_VALUE, "10", "10", {9, 2}},
                  {:EOF, "", nil, {11, 0}}
                ]}
    end

    test "quoted value" do
      assert Lexer.tokenize("created_at<'2021-11-11'") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "created_at", "created_at", {0, 10}},
                  {:LESS_THAN_COMPARATOR, "<", nil, {10, 1}},
                  {:STRING_VALUE, "'2021-11-11'", "2021-11-11", {11, 12}},
                  {:EOF, "", nil, {23, 0}}
                ]}
    end

    test "doth paths" do
      assert Lexer.tokenize("order.total<100") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "order.total", "order.total", {0, 11}},
                  {:LESS_THAN_COMPARATOR, "<", nil, {11, 1}},
                  {:STRING_VALUE, "100", "100", {12, 3}},
                  {:EOF, "", nil, {15, 0}}
                ]}
    end

    test "camelCase doth paths" do
      assert Lexer.tokenize("orderTotals.grandTotal<100") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "orderTotals.grandTotal", "order_totals.grand_total",
                   {0, 22}},
                  {:LESS_THAN_COMPARATOR, "<", nil, {22, 1}},
                  {:STRING_VALUE, "100", "100", {23, 3}},
                  {:EOF, "", nil, {26, 0}}
                ]}
    end

    test "missing value" do
      assert Lexer.tokenize("price<") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "price", "price", {0, 5}},
                  {:LESS_THAN_COMPARATOR, "<", nil, {5, 1}},
                  {:EOF, "", nil, {6, 0}}
                ]}
    end

    test "unquoted ISO date-time is invalid; require quotes" do
      assert Lexer.tokenize("created_at<2021-11-11T10:30:00Z") ==
               {:error, {:unexpected_char, ":", {24, 1}}}
    end

    test "space between field and '<' is invalid" do
      assert Lexer.tokenize("price <10") ==
               {:error, {:invalid_predicate_spacing, nil, {5, 1}}}
    end

    test "space between '<' and value is invalid" do
      assert Lexer.tokenize("price< 10") ==
               {:error, {:invalid_predicate_spacing, nil, {6, 1}}}
    end
  end

  describe "greater than or equal to comparator terms" do
    test "field in snake_case" do
      assert Lexer.tokenize("max_price>=10") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "max_price", "max_price", {0, 9}},
                  {:GREATER_THAN_OR_EQUAL_TO_COMPARATOR, ">=", nil, {9, 2}},
                  {:STRING_VALUE, "10", "10", {11, 2}},
                  {:EOF, "", nil, {13, 0}}
                ]}
    end

    test "field in camelCase → snake_case literal" do
      assert Lexer.tokenize("maxPrice>=10") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "maxPrice", "max_price", {0, 8}},
                  {:GREATER_THAN_OR_EQUAL_TO_COMPARATOR, ">=", nil, {8, 2}},
                  {:STRING_VALUE, "10", "10", {10, 2}},
                  {:EOF, "", nil, {12, 0}}
                ]}
    end

    test "quoted value" do
      assert Lexer.tokenize("created_at>='2021-11-11'") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "created_at", "created_at", {0, 10}},
                  {:GREATER_THAN_OR_EQUAL_TO_COMPARATOR, ">=", nil, {10, 2}},
                  {:STRING_VALUE, "'2021-11-11'", "2021-11-11", {12, 12}},
                  {:EOF, "", nil, {24, 0}}
                ]}
    end

    test "doth paths" do
      assert Lexer.tokenize("order.total>=100") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "order.total", "order.total", {0, 11}},
                  {:GREATER_THAN_OR_EQUAL_TO_COMPARATOR, ">=", nil, {11, 2}},
                  {:STRING_VALUE, "100", "100", {13, 3}},
                  {:EOF, "", nil, {16, 0}}
                ]}
    end

    test "camelCase doth paths" do
      assert Lexer.tokenize("orderTotals.grandTotal>=100") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "orderTotals.grandTotal", "order_totals.grand_total",
                   {0, 22}},
                  {:GREATER_THAN_OR_EQUAL_TO_COMPARATOR, ">=", nil, {22, 2}},
                  {:STRING_VALUE, "100", "100", {24, 3}},
                  {:EOF, "", nil, {27, 0}}
                ]}
    end

    test "missing value" do
      assert Lexer.tokenize("price>=") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "price", "price", {0, 5}},
                  {:GREATER_THAN_OR_EQUAL_TO_COMPARATOR, ">=", nil, {5, 2}},
                  {:EOF, "", nil, {7, 0}}
                ]}
    end

    test "unquoted ISO date-time is invalid; require quotes" do
      assert Lexer.tokenize("created_at>=2021-11-11T10:30:00Z") ==
               {:error, {:unexpected_char, ":", {25, 1}}}
    end

    test "space between field and '>=' is invalid" do
      assert Lexer.tokenize("price >=10") ==
               {:error, {:invalid_predicate_spacing, nil, {5, 1}}}
    end

    test "space between '>=' and value is invalid" do
      assert Lexer.tokenize("price>= 10") ==
               {:error, {:invalid_predicate_spacing, nil, {7, 1}}}
    end
  end

  describe "greater than comparator terms" do
    test "field in snake_case" do
      assert Lexer.tokenize("max_price>10") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "max_price", "max_price", {0, 9}},
                  {:GREATER_THAN_COMPARATOR, ">", nil, {9, 1}},
                  {:STRING_VALUE, "10", "10", {10, 2}},
                  {:EOF, "", nil, {12, 0}}
                ]}
    end

    test "field in camelCase → snake_case literal" do
      assert Lexer.tokenize("maxPrice>10") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "maxPrice", "max_price", {0, 8}},
                  {:GREATER_THAN_COMPARATOR, ">", nil, {8, 1}},
                  {:STRING_VALUE, "10", "10", {9, 2}},
                  {:EOF, "", nil, {11, 0}}
                ]}
    end

    test "quoted value" do
      assert Lexer.tokenize("created_at>'2021-11-11'") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "created_at", "created_at", {0, 10}},
                  {:GREATER_THAN_COMPARATOR, ">", nil, {10, 1}},
                  {:STRING_VALUE, "'2021-11-11'", "2021-11-11", {11, 12}},
                  {:EOF, "", nil, {23, 0}}
                ]}
    end

    test "doth paths" do
      assert Lexer.tokenize("order.total>100") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "order.total", "order.total", {0, 11}},
                  {:GREATER_THAN_COMPARATOR, ">", nil, {11, 1}},
                  {:STRING_VALUE, "100", "100", {12, 3}},
                  {:EOF, "", nil, {15, 0}}
                ]}
    end

    test "camelCase doth paths" do
      assert Lexer.tokenize("orderTotals.grandTotal>100") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "orderTotals.grandTotal", "order_totals.grand_total",
                   {0, 22}},
                  {:GREATER_THAN_COMPARATOR, ">", nil, {22, 1}},
                  {:STRING_VALUE, "100", "100", {23, 3}},
                  {:EOF, "", nil, {26, 0}}
                ]}
    end

    test "missing value" do
      assert Lexer.tokenize("price>") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "price", "price", {0, 5}},
                  {:GREATER_THAN_COMPARATOR, ">", nil, {5, 1}},
                  {:EOF, "", nil, {6, 0}}
                ]}
    end

    test "unquoted ISO date-time is invalid; require quotes" do
      assert Lexer.tokenize("created_at>2021-11-11T10:30:00Z") ==
               {:error, {:unexpected_char, ":", {24, 1}}}
    end

    test "space between field and '>' is invalid" do
      assert Lexer.tokenize("price >10") ==
               {:error, {:invalid_predicate_spacing, nil, {5, 1}}}
    end

    test "space between '>' and value is invalid" do
      assert Lexer.tokenize("price> 10") ==
               {:error, {:invalid_predicate_spacing, nil, {6, 1}}}
    end
  end

  describe "two terms" do
    test "implicit AND connector" do
      assert Lexer.tokenize("first_name:Jane created_at<'2021-11-11'") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "first_name", "first_name", {0, 10}},
                  {:EQUALITY_COMPARATOR, ":", nil, {10, 1}},
                  {:STRING_VALUE, "Jane", "Jane", {11, 4}},
                  {:AND_CONNECTOR, " ", "and", {15, 1}},
                  {:FIELD_IDENTIFIER, "created_at", "created_at", {16, 10}},
                  {:LESS_THAN_COMPARATOR, "<", nil, {26, 1}},
                  {:STRING_VALUE, "'2021-11-11'", "2021-11-11", {27, 12}},
                  {:EOF, "", nil, {39, 0}}
                ]}
    end

    test "explicit AND connector" do
      assert Lexer.tokenize("first_name:Jane AND created_at<'2021-11-11'") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "first_name", "first_name", {0, 10}},
                  {:EQUALITY_COMPARATOR, ":", nil, {10, 1}},
                  {:STRING_VALUE, "Jane", "Jane", {11, 4}},
                  {:AND_CONNECTOR, "AND", "and", {16, 3}},
                  {:FIELD_IDENTIFIER, "created_at", "created_at", {20, 10}},
                  {:LESS_THAN_COMPARATOR, "<", nil, {30, 1}},
                  {:STRING_VALUE, "'2021-11-11'", "2021-11-11", {31, 12}},
                  {:EOF, "", nil, {43, 0}}
                ]}
    end

    test "OR connector" do
      assert Lexer.tokenize("first_name:Jane OR created_at<'2021-11-11'") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "first_name", "first_name", {0, 10}},
                  {:EQUALITY_COMPARATOR, ":", nil, {10, 1}},
                  {:STRING_VALUE, "Jane", "Jane", {11, 4}},
                  {:OR_CONNECTOR, "OR", "or", {16, 2}},
                  {:FIELD_IDENTIFIER, "created_at", "created_at", {19, 10}},
                  {:LESS_THAN_COMPARATOR, "<", nil, {29, 1}},
                  {:STRING_VALUE, "'2021-11-11'", "2021-11-11", {30, 12}},
                  {:EOF, "", nil, {42, 0}}
                ]}
    end
  end

  describe "wildcard patterns" do
    test "prefix wildcard (starts_with) with simple field" do
      assert Lexer.tokenize("name:Bea*") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "name", "name", {0, 4}},
                  {:EQUALITY_COMPARATOR, ":", nil, {4, 1}},
                  {:STRING_VALUE, "Bea*", "Bea*", {5, 4}},
                  {:EOF, "", nil, {9, 0}}
                ]}
    end

    test "suffix wildcard (ends_with) with simple field" do
      assert Lexer.tokenize("name:*Inc") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "name", "name", {0, 4}},
                  {:EQUALITY_COMPARATOR, ":", nil, {4, 1}},
                  {:STRING_VALUE, "*Inc", "*Inc", {5, 4}},
                  {:EOF, "", nil, {9, 0}}
                ]}
    end

    test "prefix wildcard with dotted path" do
      assert Lexer.tokenize("organization.name:Bea*") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "organization.name", "organization.name", {0, 17}},
                  {:EQUALITY_COMPARATOR, ":", nil, {17, 1}},
                  {:STRING_VALUE, "Bea*", "Bea*", {18, 4}},
                  {:EOF, "", nil, {22, 0}}
                ]}
    end

    test "suffix wildcard with dotted path" do
      assert Lexer.tokenize("organization.name:*Inc") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "organization.name", "organization.name", {0, 17}},
                  {:EQUALITY_COMPARATOR, ":", nil, {17, 1}},
                  {:STRING_VALUE, "*Inc", "*Inc", {18, 4}},
                  {:EOF, "", nil, {22, 0}}
                ]}
    end

    test "wildcards in compound queries" do
      assert Lexer.tokenize("status:live AND organization.name:Bea*") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "status", "status", {0, 6}},
                  {:EQUALITY_COMPARATOR, ":", nil, {6, 1}},
                  {:STRING_VALUE, "live", "live", {7, 4}},
                  {:AND_CONNECTOR, "AND", "and", {12, 3}},
                  {:FIELD_IDENTIFIER, "organization.name", "organization.name", {16, 17}},
                  {:EQUALITY_COMPARATOR, ":", nil, {33, 1}},
                  {:STRING_VALUE, "Bea*", "Bea*", {34, 4}},
                  {:EOF, "", nil, {38, 0}}
                ]}
    end

    test "quoted wildcard is treated as literal" do
      assert Lexer.tokenize("name:'Bea*'") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "name", "name", {0, 4}},
                  {:EQUALITY_COMPARATOR, ":", nil, {4, 1}},
                  {:STRING_VALUE, "'Bea*'", "Bea*", {5, 6}},
                  {:EOF, "", nil, {11, 0}}
                ]}
    end
  end

  describe "grouped clauses" do
    test "explicit OR/AND with parentheses and implied AND inside" do
      query =
        """
        status:live OR status:draft
        AND
        (created_at>'2021-11-01' created_at<'2021-11-11')
        """
        |> String.trim()

      assert Lexer.tokenize(query) ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "status", "status", {0, 6}},
                  {:EQUALITY_COMPARATOR, ":", nil, {6, 1}},
                  {:STRING_VALUE, "live", "live", {7, 4}},
                  {:OR_CONNECTOR, "OR", "or", {12, 2}},
                  {:FIELD_IDENTIFIER, "status", "status", {15, 6}},
                  {:EQUALITY_COMPARATOR, ":", nil, {21, 1}},
                  {:STRING_VALUE, "draft", "draft", {22, 5}},
                  {:AND_CONNECTOR, "AND", "and", {28, 3}},
                  {:LEFT_PAREN, "(", nil, {32, 1}},
                  {:FIELD_IDENTIFIER, "created_at", "created_at", {33, 10}},
                  {:GREATER_THAN_COMPARATOR, ">", nil, {43, 1}},
                  {:STRING_VALUE, "'2021-11-01'", "2021-11-01", {44, 12}},
                  {:AND_CONNECTOR, " ", "and", {56, 1}},
                  {:FIELD_IDENTIFIER, "created_at", "created_at", {57, 10}},
                  {:LESS_THAN_COMPARATOR, "<", nil, {67, 1}},
                  {:STRING_VALUE, "'2021-11-11'", "2021-11-11", {68, 12}},
                  {:RIGHT_PAREN, ")", nil, {80, 1}},
                  {:EOF, "", nil, {81, 0}}
                ]}
    end

    test "implicit AND before '(' and within parens across newlines" do
      query =
        """
        status:live OR status:draft
        (
          created_at>'2021-11-01'
          created_at<'2021-11-11'
        )
        """
        |> String.trim()

      assert Lexer.tokenize(query) ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "status", "status", {0, 6}},
                  {:EQUALITY_COMPARATOR, ":", nil, {6, 1}},
                  {:STRING_VALUE, "live", "live", {7, 4}},
                  {:OR_CONNECTOR, "OR", "or", {12, 2}},
                  {:FIELD_IDENTIFIER, "status", "status", {15, 6}},
                  {:EQUALITY_COMPARATOR, ":", nil, {21, 1}},
                  {:STRING_VALUE, "draft", "draft", {22, 5}},
                  {:AND_CONNECTOR, "\n", "and", {27, 1}},
                  {:LEFT_PAREN, "(", nil, {28, 1}},
                  {:FIELD_IDENTIFIER, "created_at", "created_at", {32, 10}},
                  {:GREATER_THAN_COMPARATOR, ">", nil, {42, 1}},
                  {:STRING_VALUE, "'2021-11-01'", "2021-11-01", {43, 12}},
                  {:AND_CONNECTOR, "\n  ", "and", {55, 3}},
                  {:FIELD_IDENTIFIER, "created_at", "created_at", {58, 10}},
                  {:LESS_THAN_COMPARATOR, "<", nil, {68, 1}},
                  {:STRING_VALUE, "'2021-11-11'", "2021-11-11", {69, 12}},
                  {:RIGHT_PAREN, ")", nil, {82, 1}},
                  {:EOF, "", nil, {83, 0}}
                ]}
    end

    test "ORs + nested groups + explicit AND, with implied ANDs inside groups" do
      query =
        """
        (status:live time_end<='2022-01-21T12:33:15.661Z')
        OR
        status:draft
        OR
        (status:live time_start>='2022-01-21T12:33:15.661Z')
        OR
        (status:live (time_end>'2022-01-21T12:33:15.661Z' time_start<'2022-01-21T12:33:15.661Z'))
        OR status:building
        AND
        searchterm
        """
        |> String.trim()

      assert {:ok, toks} = Lexer.tokenize(query)

      assert [
               {:LEFT_PAREN, "(", nil, _},
               {:FIELD_IDENTIFIER, "status", "status", _},
               {:EQUALITY_COMPARATOR, ":", nil, _},
               {:STRING_VALUE, "live", "live", _},
               {:AND_CONNECTOR, " ", "and", _},
               {:FIELD_IDENTIFIER, "time_end", "time_end", _},
               {:LESS_THAN_OR_EQUAL_TO_COMPARATOR, "<=", nil, _},
               {:STRING_VALUE, "'2022-01-21T12:33:15.661Z'", "2022-01-21T12:33:15.661Z", _},
               {:RIGHT_PAREN, ")", nil, _},
               {:OR_CONNECTOR, "OR", "or", _},
               {:FIELD_IDENTIFIER, "status", "status", _},
               {:EQUALITY_COMPARATOR, ":", nil, _},
               {:STRING_VALUE, "draft", "draft", _},
               {:OR_CONNECTOR, "OR", "or", _},
               {:LEFT_PAREN, "(", nil, _},
               {:FIELD_IDENTIFIER, "status", "status", _},
               {:EQUALITY_COMPARATOR, ":", nil, _},
               {:STRING_VALUE, "live", "live", _},
               {:AND_CONNECTOR, " ", "and", _},
               {:FIELD_IDENTIFIER, "time_start", "time_start", _},
               {:GREATER_THAN_OR_EQUAL_TO_COMPARATOR, ">=", nil, _},
               {:STRING_VALUE, "'2022-01-21T12:33:15.661Z'", "2022-01-21T12:33:15.661Z", _},
               {:RIGHT_PAREN, ")", nil, _},
               {:OR_CONNECTOR, "OR", "or", _},
               {:LEFT_PAREN, "(", nil, _},
               {:FIELD_IDENTIFIER, "status", "status", _},
               {:EQUALITY_COMPARATOR, ":", nil, _},
               {:STRING_VALUE, "live", "live", _},
               {:AND_CONNECTOR, " ", "and", _},
               {:LEFT_PAREN, "(", nil, _},
               {:FIELD_IDENTIFIER, "time_end", "time_end", _},
               {:GREATER_THAN_COMPARATOR, ">", nil, _},
               {:STRING_VALUE, "'2022-01-21T12:33:15.661Z'", "2022-01-21T12:33:15.661Z", _},
               {:AND_CONNECTOR, " ", "and", _},
               {:FIELD_IDENTIFIER, "time_start", "time_start", _},
               {:LESS_THAN_COMPARATOR, "<", nil, _},
               {:STRING_VALUE, "'2022-01-21T12:33:15.661Z'", "2022-01-21T12:33:15.661Z", _},
               {:RIGHT_PAREN, ")", nil, _},
               {:RIGHT_PAREN, ")", nil, _},
               {:OR_CONNECTOR, "OR", "or", _},
               {:FIELD_IDENTIFIER, "status", "status", _},
               {:EQUALITY_COMPARATOR, ":", nil, _},
               {:STRING_VALUE, "building", "building", _},
               {:AND_CONNECTOR, "AND", "and", _},
               {:STRING_VALUE, "searchterm", "searchterm", _},
               {:EOF, "", nil, _}
             ] = toks
    end
  end

  describe "modifiers and connector boundaries" do
    test "dash NOT before predicate" do
      assert Lexer.tokenize("-status:live") ==
               {:ok,
                [
                  {:NOT_MODIFIER, "-", nil, {0, 1}},
                  {:FIELD_IDENTIFIER, "status", "status", {1, 6}},
                  {:EQUALITY_COMPARATOR, ":", nil, {7, 1}},
                  {:STRING_VALUE, "live", "live", {8, 4}},
                  {:EOF, "", nil, {12, 0}}
                ]}
    end

    test "dash NOT before group" do
      assert Lexer.tokenize("-(status:live)") ==
               {:ok,
                [
                  {:NOT_MODIFIER, "-", nil, {0, 1}},
                  {:LEFT_PAREN, "(", nil, {1, 1}},
                  {:FIELD_IDENTIFIER, "status", "status", {2, 6}},
                  {:EQUALITY_COMPARATOR, ":", nil, {8, 1}},
                  {:STRING_VALUE, "live", "live", {9, 4}},
                  {:RIGHT_PAREN, ")", nil, {13, 1}},
                  {:EOF, "", nil, {14, 0}}
                ]}
    end

    test "keyword NOT (case-insensitive) before predicate" do
      assert Lexer.tokenize("NOT status:live") ==
               {:ok,
                [
                  {:NOT_MODIFIER, "NOT", nil, {0, 3}},
                  {:FIELD_IDENTIFIER, "status", "status", {4, 6}},
                  {:EQUALITY_COMPARATOR, ":", nil, {10, 1}},
                  {:STRING_VALUE, "live", "live", {11, 4}},
                  {:EOF, "", nil, {15, 0}}
                ]}
    end

    test "keyword NOT must be at a term boundary (NOTstatus is not a modifier)" do
      assert Lexer.tokenize("NOTstatus:live") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "NOTstatus", "notstatus", {0, 9}},
                  {:EQUALITY_COMPARATOR, ":", nil, {9, 1}},
                  {:STRING_VALUE, "live", "live", {10, 4}},
                  {:EOF, "", nil, {14, 0}}
                ]}
    end

    test "OR connector is case-insensitive" do
      assert Lexer.tokenize("status:live or status:draft") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "status", "status", {0, 6}},
                  {:EQUALITY_COMPARATOR, ":", nil, {6, 1}},
                  {:STRING_VALUE, "live", "live", {7, 4}},
                  {:OR_CONNECTOR, "or", "or", {12, 2}},
                  {:FIELD_IDENTIFIER, "status", "status", {15, 6}},
                  {:EQUALITY_COMPARATOR, ":", nil, {21, 1}},
                  {:STRING_VALUE, "draft", "draft", {22, 5}},
                  {:EOF, "", nil, {27, 0}}
                ]}
    end

    test "AND connector is case-insensitive" do
      assert Lexer.tokenize("status:live And status:draft") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "status", "status", {0, 6}},
                  {:EQUALITY_COMPARATOR, ":", nil, {6, 1}},
                  {:STRING_VALUE, "live", "live", {7, 4}},
                  {:AND_CONNECTOR, "And", "and", {12, 3}},
                  {:FIELD_IDENTIFIER, "status", "status", {16, 6}},
                  {:EQUALITY_COMPARATOR, ":", nil, {22, 1}},
                  {:STRING_VALUE, "draft", "draft", {23, 5}},
                  {:EOF, "", nil, {28, 0}}
                ]}
    end

    test "connector must be a whole word (ORstatus is not a connector)" do
      assert Lexer.tokenize("status:live ORstatus:draft") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "status", "status", {0, 6}},
                  {:EQUALITY_COMPARATOR, ":", nil, {6, 1}},
                  {:STRING_VALUE, "live", "live", {7, 4}},
                  {:AND_CONNECTOR, " ", "and", {11, 1}},
                  {:FIELD_IDENTIFIER, "ORstatus", "orstatus", {12, 8}},
                  {:EQUALITY_COMPARATOR, ":", nil, {20, 1}},
                  {:STRING_VALUE, "draft", "draft", {21, 5}},
                  {:EOF, "", nil, {26, 0}}
                ]}
    end

    test "hyphenated field name is not mistaken for dash NOT" do
      assert Lexer.tokenize("user-name:foo") ==
               {:ok,
                [
                  {:FIELD_IDENTIFIER, "user-name", "user_name", {0, 9}},
                  {:EQUALITY_COMPARATOR, ":", nil, {9, 1}},
                  {:STRING_VALUE, "foo", "foo", {10, 3}},
                  {:EOF, "", nil, {13, 0}}
                ]}
    end

    test "implied AND after closing parenthesis before next term" do
      assert Lexer.tokenize("(status:live) searchterm") ==
               {:ok,
                [
                  {:LEFT_PAREN, "(", nil, {0, 1}},
                  {:FIELD_IDENTIFIER, "status", "status", {1, 6}},
                  {:EQUALITY_COMPARATOR, ":", nil, {7, 1}},
                  {:STRING_VALUE, "live", "live", {8, 4}},
                  {:RIGHT_PAREN, ")", nil, {12, 1}},
                  {:AND_CONNECTOR, " ", "and", {13, 1}},
                  {:STRING_VALUE, "searchterm", "searchterm", {14, 10}},
                  {:EOF, "", nil, {24, 0}}
                ]}
    end
  end

  describe "list literals" do
    test "simple quoted list as bare tokens" do
      assert Lexer.tokenize("('a','b','c')") ==
               {:ok,
                [
                  {:LEFT_PAREN, "(", nil, {0, 1}},
                  {:STRING_VALUE, "'a'", "a", {1, 3}},
                  {:COMMA, ",", nil, {4, 1}},
                  {:STRING_VALUE, "'b'", "b", {5, 3}},
                  {:COMMA, ",", nil, {8, 1}},
                  {:STRING_VALUE, "'c'", "c", {9, 3}},
                  {:RIGHT_PAREN, ")", nil, {12, 1}},
                  {:EOF, "", nil, {13, 0}}
                ]}
    end

    test "spaces and newlines around commas don't insert ANDs" do
      query = "(\n 'a' ,  'b'  ,\n'c' \n)"

      assert Lexer.tokenize(query) ==
               {:ok,
                [
                  {:LEFT_PAREN, "(", nil, {0, 1}},
                  {:STRING_VALUE, "'a'", "a", {3, 3}},
                  {:COMMA, ",", nil, {7, 1}},
                  {:STRING_VALUE, "'b'", "b", {10, 3}},
                  {:COMMA, ",", nil, {15, 1}},
                  {:STRING_VALUE, "'c'", "c", {17, 3}},
                  {:RIGHT_PAREN, ")", nil, {22, 1}},
                  {:EOF, "", nil, {23, 0}}
                ]}
    end

    test "implied AND after list before next term" do
      assert Lexer.tokenize("('a','b') search") ==
               {:ok,
                [
                  {:LEFT_PAREN, "(", nil, {0, 1}},
                  {:STRING_VALUE, "'a'", "a", {1, 3}},
                  {:COMMA, ",", nil, {4, 1}},
                  {:STRING_VALUE, "'b'", "b", {5, 3}},
                  {:RIGHT_PAREN, ")", nil, {8, 1}},
                  {:AND_CONNECTOR, " ", "and", {9, 1}},
                  {:STRING_VALUE, "search", "search", {10, 6}},
                  {:EOF, "", nil, {16, 0}}
                ]}
    end
  end

  describe "set operators" do
    alias Lexer

    test "IN with quoted list" do
      assert {:ok, toks} = Lexer.tokenize("status IN ('live','draft')")

      assert [
               {:FIELD_IDENTIFIER, "status", "status", {0, 6}},
               {:SET_IN, in_lex, :in, {7, 2}},
               {:LEFT_PAREN, "(", nil, {10, 1}},
               {:STRING_VALUE, "'live'", "live", {11, 6}},
               {:COMMA, ",", nil, {17, 1}},
               {:STRING_VALUE, "'draft'", "draft", {18, 7}},
               {:RIGHT_PAREN, ")", nil, {25, 1}},
               {:EOF, "", nil, {26, 0}}
             ] = toks

      assert String.upcase(in_lex) == "IN"
    end

    test "NOT IN with quoted list" do
      assert {:ok, toks} = Lexer.tokenize("status NOT IN ('live','draft')")

      assert [
               {:FIELD_IDENTIFIER, "status", "status", {0, 6}},
               {:SET_NOT_IN, notin_lex, :not_in, {7, 6}},
               {:LEFT_PAREN, "(", nil, {14, 1}},
               {:STRING_VALUE, "'live'", "live", {15, 6}},
               {:COMMA, ",", nil, {21, 1}},
               {:STRING_VALUE, "'draft'", "draft", {22, 7}},
               {:RIGHT_PAREN, ")", nil, {29, 1}},
               {:EOF, "", nil, {30, 0}}
             ] = toks

      assert String.upcase(notin_lex) == "NOT IN"
    end

    test "case-insensitive keywords + flexible whitespace" do
      assert {:ok, toks} = Lexer.tokenize("status  in  ( 'live' ,  'draft' )")

      assert [
               {:FIELD_IDENTIFIER, "status", "status", {0, 6}},
               {:SET_IN, in_lex, :in, {8, 2}},
               {:LEFT_PAREN, "(", nil, {12, 1}},
               {:STRING_VALUE, "'live'", "live", {14, 6}},
               {:COMMA, ",", nil, {21, 1}},
               {:STRING_VALUE, "'draft'", "draft", {24, 7}},
               {:RIGHT_PAREN, ")", nil, {32, 1}},
               {:EOF, "", nil, {33, 0}}
             ] = toks

      assert String.upcase(in_lex) == "IN"
    end

    test "no implied AND inside lists (whitespace before comma/close)" do
      assert {:ok, toks} = Lexer.tokenize("status IN (\n  'live' ,\n  'draft'\n)")

      refute Enum.any?(toks, fn {t, _, _, _} -> t == :AND_CONNECTOR end)

      assert [
               {:FIELD_IDENTIFIER, "status", "status", {0, 6}},
               {:SET_IN, _in_lex, :in, {7, 2}},
               {:LEFT_PAREN, "(", nil, {10, 1}},
               {:STRING_VALUE, "'live'", "live", {14, 6}},
               {:COMMA, ",", nil, {21, 1}},
               {:STRING_VALUE, "'draft'", "draft", {25, 7}},
               {:RIGHT_PAREN, ")", nil, {33, 1}},
               {:EOF, "", nil, {34, 0}}
             ] = toks
    end

    test "field followed by bare word starting with 'in' is not a set op" do
      assert Lexer.tokenize("status index") ==
               {:ok,
                [
                  {:STRING_VALUE, "status", "status", {0, 6}},
                  {:AND_CONNECTOR, " ", "and", {6, 1}},
                  {:STRING_VALUE, "index", "index", {7, 5}},
                  {:EOF, "", nil, {12, 0}}
                ]}
    end

    test "ALL with quoted list" do
      assert {:ok, toks} = Lexer.tokenize("tags.name ALL ('backend','urgent')")

      assert [
               {:FIELD_IDENTIFIER, "tags.name", "tags.name", {0, 9}},
               {:SET_CONTAINS_ALL, all_lex, :contains_all, {10, 3}},
               {:LEFT_PAREN, "(", nil, {14, 1}},
               {:STRING_VALUE, "'backend'", "backend", {15, 9}},
               {:COMMA, ",", nil, {24, 1}},
               {:STRING_VALUE, "'urgent'", "urgent", {25, 8}},
               {:RIGHT_PAREN, ")", nil, {33, 1}},
               {:EOF, "", nil, {34, 0}}
             ] = toks

      assert String.upcase(all_lex) == "ALL"
    end

    test "ALL case-insensitive with flexible whitespace" do
      assert {:ok, toks} = Lexer.tokenize("tags.name  all  ('backend', 'urgent')")

      assert [
               {:FIELD_IDENTIFIER, "tags.name", "tags.name", {0, 9}},
               {:SET_CONTAINS_ALL, all_lex, :contains_all, {11, 3}},
               {:LEFT_PAREN, "(", nil, {16, 1}},
               {:STRING_VALUE, "'backend'", "backend", {17, 9}},
               {:COMMA, ",", nil, {26, 1}},
               {:STRING_VALUE, "'urgent'", "urgent", {28, 8}},
               {:RIGHT_PAREN, ")", nil, {36, 1}},
               {:EOF, "", nil, {37, 0}}
             ] = toks

      assert String.upcase(all_lex) == "ALL"
    end

    test "field followed by bare word starting with 'all' is not a set op" do
      assert Lexer.tokenize("status allowed") ==
               {:ok,
                [
                  {:STRING_VALUE, "status", "status", {0, 6}},
                  {:AND_CONNECTOR, " ", "and", {6, 1}},
                  {:STRING_VALUE, "allowed", "allowed", {7, 7}},
                  {:EOF, "", nil, {14, 0}}
                ]}
    end
  end

  describe "errors" do
    test "nil value" do
      assert Lexer.tokenize(nil) == {:error, :invalid_input}
    end

    test "non binary query" do
      assert Lexer.tokenize(123) == {:error, :invalid_input}
    end

    test "space between field and ':' is invalid" do
      assert Lexer.tokenize("first_name : Jane") ==
               {:error, {:invalid_predicate_spacing, nil, {10, 1}}}
    end

    test "space between ':' and value is invalid" do
      assert Lexer.tokenize("first_name: Jane") ==
               {:error, {:invalid_predicate_spacing, nil, {11, 1}}}
    end

    test "'=' equality comparator is invalid" do
      assert Lexer.tokenize("firstName='Jane'") ==
               {:error, {:invalid_comparator, "=", {9, 1}}}

      assert Lexer.tokenize("firstName = 'Jane Doe'") ==
               {:error, {:invalid_comparator, "=", {10, 1}}}
    end

    test "split operator is invalid ('< =')" do
      assert Lexer.tokenize("count:< =10") ==
               {:error, {:broken_operator, "< =", {7, 2}}}
    end

    test "NOT must be followed by space to be a modifier" do
      assert {:ok, toks} = Lexer.tokenize("NOT(status:live)")

      assert [
               {:STRING_VALUE, "NOT", "NOT", {0, 3}},
               {:LEFT_PAREN, "(", nil, {3, 1}},
               {:FIELD_IDENTIFIER, "status", "status", {4, 6}},
               {:EQUALITY_COMPARATOR, ":", nil, {10, 1}},
               {:STRING_VALUE, "live", "live", {11, 4}},
               {:RIGHT_PAREN, ")", nil, {15, 1}},
               {:EOF, "", nil, {16, 0}}
             ] = toks
    end
  end
end
