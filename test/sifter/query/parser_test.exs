defmodule Sifter.Query.ParserTest do
  use ExUnit.Case, async: true
  alias Sifter.Query.Parser
  alias Sifter.AST

  defp eq(path, v), do: %AST.Cmp{field_path: path, op: :eq, value: v}
  defp lt(path, v), do: %AST.Cmp{field_path: path, op: :lt, value: v}
  defp lte(path, v), do: %AST.Cmp{field_path: path, op: :lte, value: v}
  defp gt(path, v), do: %AST.Cmp{field_path: path, op: :gt, value: v}
  defp gte(path, v), do: %AST.Cmp{field_path: path, op: :gte, value: v}
  defp inn(path, vs), do: %AST.Cmp{field_path: path, op: :in, value: vs}
  defp nin(path, vs), do: %AST.Cmp{field_path: path, op: :nin, value: vs}
  defp contains_all(path, vs), do: %AST.Cmp{field_path: path, op: :contains_all, value: vs}

  describe "simple inputs" do
    test "single EOF token" do
      assert Parser.parse([{:EOF, "", nil, {0, 0}}]) ==
               {:ok, %AST.And{children: []}}
    end

    test "bare full-text token" do
      tokens = [
        {:STRING_VALUE, "Jane", "Jane", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Parser.parse(tokens) ==
               {:ok, %AST.FullText{term: "Jane"}}
    end

    test "two bare terms with implied AND" do
      tokens = [
        {:STRING_VALUE, "Jane", "Jane", {0, 0}},
        {:AND_CONNECTOR, " ", "and", {0, 0}},
        {:STRING_VALUE, "Doe", "Doe", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Parser.parse(tokens) ==
               {:ok,
                %AST.And{
                  children: [
                    %AST.FullText{term: "Jane"},
                    %AST.FullText{term: "Doe"}
                  ]
                }}
    end
  end

  describe "fielded comparators" do
    test "equality comparator" do
      tokens = [
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "live", "live", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Parser.parse(tokens) ==
               {:ok, eq(["status"], "live")}
    end

    test "equality comparator with wildcard" do
      tokens = [
        {:FIELD_IDENTIFIER, "title", "title", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "'*foo'", "*foo", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:ok, %AST.Cmp{op: :eq, field_path: ["title"], value: "*foo"}} = Parser.parse(tokens)
    end

    test "dot path splits into segments" do
      tokens = [
        {:FIELD_IDENTIFIER, "orderTotals.grandTotal", "order_totals.grand_total", {0, 0}},
        {:GREATER_THAN_COMPARATOR, ">", nil, {0, 0}},
        {:STRING_VALUE, "100", "100", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Parser.parse(tokens) ==
               {:ok, gt(["order_totals", "grand_total"], "100")}
    end

    test "all relational operators" do
      t1 = [
        {:FIELD_IDENTIFIER, "price", "price", {0, 0}},
        {:LESS_THAN_COMPARATOR, "<", nil, {0, 0}},
        {:STRING_VALUE, "10", "10", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Parser.parse(t1) == {:ok, lt(["price"], "10")}

      t2 = [
        {:FIELD_IDENTIFIER, "price", "price", {0, 0}},
        {:LESS_THAN_OR_EQUAL_TO_COMPARATOR, "<=", nil, {0, 0}},
        {:STRING_VALUE, "10", "10", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Parser.parse(t2) == {:ok, lte(["price"], "10")}

      t3 = [
        {:FIELD_IDENTIFIER, "price", "price", {0, 0}},
        {:GREATER_THAN_COMPARATOR, ">", nil, {0, 0}},
        {:STRING_VALUE, "10", "10", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Parser.parse(t3) == {:ok, gt(["price"], "10")}

      t4 = [
        {:FIELD_IDENTIFIER, "price", "price", {0, 0}},
        {:GREATER_THAN_OR_EQUAL_TO_COMPARATOR, ">=", nil, {0, 0}},
        {:STRING_VALUE, "10", "10", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Parser.parse(t4) == {:ok, gte(["price"], "10")}
    end
  end

  describe "AND/OR and precedence" do
    test "implicit AND between predicates" do
      tokens = [
        {:FIELD_IDENTIFIER, "first_name", "first_name", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "Jane", "Jane", {0, 0}},
        {:AND_CONNECTOR, " ", "and", {0, 0}},
        {:FIELD_IDENTIFIER, "created_at", "created_at", {0, 0}},
        {:LESS_THAN_COMPARATOR, "<", nil, {0, 0}},
        {:STRING_VALUE, "'2021-11-11'", "2021-11-11", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Parser.parse(tokens) ==
               {:ok,
                %AST.And{
                  children: [
                    eq(["first_name"], "Jane"),
                    lt(["created_at"], "2021-11-11")
                  ]
                }}
    end

    test "AND binds tighter than OR: A OR B AND C  =>  Or(A, And(B,C))" do
      tokens = [
        {:FIELD_IDENTIFIER, "a", "a", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "x", "x", {0, 0}},
        {:OR_CONNECTOR, "OR", "or", {0, 0}},
        {:FIELD_IDENTIFIER, "b", "b", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "y", "y", {0, 0}},
        {:AND_CONNECTOR, "AND", "and", {0, 0}},
        {:FIELD_IDENTIFIER, "c", "c", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "z", "z", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:ok, %AST.Or{children: [left, %AST.And{children: [mid, right]}]}} =
               Parser.parse(tokens)

      assert left == eq(["a"], "x")
      assert mid == eq(["b"], "y")
      assert right == eq(["c"], "z")
    end

    test "grouping overrides precedence: (A OR B) AND C" do
      tokens = [
        {:LEFT_PAREN, "(", nil, {0, 0}},
        {:FIELD_IDENTIFIER, "a", "a", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "x", "x", {0, 0}},
        {:OR_CONNECTOR, "OR", "or", {0, 0}},
        {:FIELD_IDENTIFIER, "b", "b", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "y", "y", {0, 0}},
        {:RIGHT_PAREN, ")", nil, {0, 0}},
        {:AND_CONNECTOR, "AND", "and", {0, 0}},
        {:FIELD_IDENTIFIER, "c", "c", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "z", "z", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:ok, %AST.And{children: [%AST.Or{children: [a, b]}, c]}} = Parser.parse(tokens)
      assert a == eq(["a"], "x")
      assert b == eq(["b"], "y")
      assert c == eq(["c"], "z")
    end
  end

  describe "NOT modifier" do
    test "keyword NOT before predicate" do
      tokens = [
        {:NOT_MODIFIER, "NOT", nil, {0, 0}},
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "live", "live", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Parser.parse(tokens) ==
               {:ok, %AST.Not{expr: eq(["status"], "live")}}
    end

    test "dash NOT before group" do
      tokens = [
        {:NOT_MODIFIER, "-", nil, {0, 0}},
        {:LEFT_PAREN, "(", nil, {0, 0}},
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "live", "live", {0, 0}},
        {:OR_CONNECTOR, "OR", "or", {0, 0}},
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "draft", "draft", {0, 0}},
        {:RIGHT_PAREN, ")", nil, {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:ok, %AST.Not{expr: %AST.Or{children: [a, b]}}} = Parser.parse(tokens)
      assert a == eq(["status"], "live")
      assert b == eq(["status"], "draft")
    end
  end

  describe "NULL sentinel" do
    test "NULL with equality" do
      tokens = [
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "NULL", "NULL", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Parser.parse(tokens) ==
               {:ok, eq(["status"], nil)}
    end

    test "NULL with NOT modifier" do
      tokens = [
        {:NOT_MODIFIER, "NOT", nil, {0, 0}},
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "NULL", "NULL", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Sifter.Query.Parser.parse(tokens) ==
               {:ok,
                %Sifter.AST.Not{
                  expr: eq(["status"], nil)
                }}
    end

    test "NULL literal" do
      tokens = [
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "'NULL'", "NULL", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Sifter.Query.Parser.parse(tokens) ==
               {:ok, eq(["status"], "NULL")}
    end
  end

  describe "set membership (IN / NOT IN / ALL)" do
    test "IN with quoted list" do
      tokens = [
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:SET_IN, "IN", :in, {0, 0}},
        {:LEFT_PAREN, "(", nil, {0, 0}},
        {:STRING_VALUE, "'live'", "live", {0, 0}},
        {:COMMA, ",", nil, {0, 0}},
        {:STRING_VALUE, "'draft'", "draft", {0, 0}},
        {:RIGHT_PAREN, ")", nil, {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Parser.parse(tokens) ==
               {:ok, inn(["status"], ["live", "draft"])}
    end

    test "NOT IN with quoted list" do
      tokens = [
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:SET_NOT_IN, "NOT IN", :not_in, {0, 0}},
        {:LEFT_PAREN, "(", nil, {0, 0}},
        {:STRING_VALUE, "'live'", "live", {0, 0}},
        {:COMMA, ",", nil, {0, 0}},
        {:STRING_VALUE, "'draft'", "draft", {0, 0}},
        {:RIGHT_PAREN, ")", nil, {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Parser.parse(tokens) ==
               {:ok, nin(["status"], ["live", "draft"])}
    end

    test "IN with NULL in list" do
      tokens = [
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:SET_IN, "IN", :in, {0, 0}},
        {:LEFT_PAREN, "(", nil, {0, 0}},
        {:STRING_VALUE, "'live'", "live", {0, 0}},
        {:COMMA, ",", nil, {0, 0}},
        {:STRING_VALUE, "NULL", "NULL", {0, 0}},
        {:RIGHT_PAREN, ")", nil, {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Parser.parse(tokens) ==
               {:ok, inn(["status"], ["live", nil])}
    end

    test "NOT IN with NULL in list" do
      tokens = [
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:SET_NOT_IN, "NOT IN", :not_in, {0, 0}},
        {:LEFT_PAREN, "(", nil, {0, 0}},
        {:STRING_VALUE, "'live'", "live", {0, 0}},
        {:COMMA, ",", nil, {0, 0}},
        {:STRING_VALUE, "NULL", "NULL", {0, 0}},
        {:RIGHT_PAREN, ")", nil, {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Parser.parse(tokens) ==
               {:ok, nin(["status"], ["live", nil])}
    end

    test "ALL with quoted list" do
      tokens = [
        {:FIELD_IDENTIFIER, "tags.name", "tags.name", {0, 0}},
        {:SET_CONTAINS_ALL, "ALL", :contains_all, {0, 0}},
        {:LEFT_PAREN, "(", nil, {0, 0}},
        {:STRING_VALUE, "'backend'", "backend", {0, 0}},
        {:COMMA, ",", nil, {0, 0}},
        {:STRING_VALUE, "'urgent'", "urgent", {0, 0}},
        {:RIGHT_PAREN, ")", nil, {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Parser.parse(tokens) ==
               {:ok, contains_all(["tags", "name"], ["backend", "urgent"])}
    end

    test "error: IN without a list" do
      tokens = [
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:SET_IN, "IN", :in, {0, 0}},
        {:STRING_VALUE, "'live'", "live", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:expected_list_after_set_operator, _tkn}} = Parser.parse(tokens)
    end

    test "error: bare list not attached to a set op" do
      tokens = [
        {:LEFT_PAREN, "(", nil, {0, 0}},
        {:STRING_VALUE, "'a'", "a", {0, 0}},
        {:COMMA, ",", nil, {0, 0}},
        {:STRING_VALUE, "'b'", "b", {0, 0}},
        {:RIGHT_PAREN, ")", nil, {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:unexpected_token, {:LEFT_PAREN, "(", nil, {0, 0}}}} =
               Parser.parse(tokens)
    end
  end

  describe "implied AND adjacent to parens" do
    test ") term" do
      tokens = [
        {:LEFT_PAREN, "(", nil, {0, 0}},
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "live", "live", {0, 0}},
        {:RIGHT_PAREN, ")", nil, {0, 0}},
        {:AND_CONNECTOR, " ", "and", {0, 0}},
        {:STRING_VALUE, "searchterm", "searchterm", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert Parser.parse(tokens) ==
               {:ok,
                %AST.And{
                  children: [
                    eq(["status"], "live"),
                    %AST.FullText{term: "searchterm"}
                  ]
                }}
    end
  end

  describe "parser errors" do
    test "starts with connector" do
      tokens = [
        {:OR_CONNECTOR, "OR", "or", {0, 0}},
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "draft", "draft", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:unrecognized_token, {:OR_CONNECTOR, "OR", "or", {0, 0}}}} =
               Parser.parse(tokens)
    end

    test "two consecutive connectors" do
      tokens = [
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "draft", "draft", {0, 0}},
        {:AND_CONNECTOR, "AND", "and", {0, 0}},
        {:OR_CONNECTOR, "OR", "or", {0, 0}},
        {:STRING_VALUE, "term", "term", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:unrecognized_token, {:OR_CONNECTOR, "OR", "or", {0, 0}}}} =
               Parser.parse(tokens)
    end

    test "invalid token after field identifier" do
      tokens = [
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:OR_CONNECTOR, "OR", "or", {0, 0}},
        {:STRING_VALUE, "draft", "draft", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:unexpected_token, {:OR_CONNECTOR, "OR", "or", {0, 0}}}} =
               Parser.parse(tokens)
    end

    test "missing right parenthesis" do
      tokens = [
        {:STRING_VALUE, "live", "live", {0, 0}},
        {:OR_CONNECTOR, "OR", "or", {0, 0}},
        {:LEFT_PAREN, "(", nil, {0, 0}},
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "draft", "draft", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:missing_right_paren, {:LEFT_PAREN, "(", nil, {0, 0}}}} =
               Parser.parse(tokens)
    end

    test "trailing connector" do
      tokens = [
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "live", "live", {0, 0}},
        {:AND_CONNECTOR, "AND", "and", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:unexpected_eof_after_operator, {:AND_CONNECTOR, "AND", "and", {0, 0}}}} =
               Parser.parse(tokens)
    end

    test "missing RHS after a comparator" do
      tokens = [
        {:FIELD_IDENTIFIER, "price", "price", {0, 0}},
        {:LESS_THAN_COMPARATOR, "<", nil, {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:missing_rhs, {:LESS_THAN_COMPARATOR, "<", nil, {0, 0}}}} =
               Parser.parse(tokens)
    end

    test "IN / NOT IN / ALL must be followed by a list" do
      tokens = [
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:SET_IN, "IN", :in, {0, 0}},
        {:STRING_VALUE, "'live'", "live", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:expected_list_after_set_operator, {:SET_IN, "IN", :in, {0, 0}}}} =
               Parser.parse(tokens)

      tokens = [
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:SET_NOT_IN, "NOT IN", :not_in, {0, 0}},
        {:STRING_VALUE, "'live'", "live", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error,
              {:expected_list_after_set_operator, {:SET_NOT_IN, "NOT IN", :not_in, {0, 0}}}} =
               Parser.parse(tokens)

      tokens = [
        {:FIELD_IDENTIFIER, "tags.name", "tags.name", {0, 0}},
        {:SET_CONTAINS_ALL, "ALL", :contains_all, {0, 0}},
        {:STRING_VALUE, "'backend'", "backend", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error,
              {:expected_list_after_set_operator,
               {:SET_CONTAINS_ALL, "ALL", :contains_all, {0, 0}}}} =
               Parser.parse(tokens)
    end

    test "empty list" do
      tokens = [
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:SET_IN, "IN", :in, {0, 0}},
        {:LEFT_PAREN, "(", nil, {0, 0}},
        {:RIGHT_PAREN, ")", nil, {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:empty_list, {:LEFT_PAREN, "(", nil, {0, 0}}}} = Parser.parse(tokens)
    end

    test "trailing comma" do
      tokens = [
        {:LEFT_PAREN, "(", nil, {0, 0}},
        {:STRING_VALUE, "'a'", "a", {0, 0}},
        {:COMMA, ",", nil, {0, 0}},
        {:RIGHT_PAREN, ")", nil, {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:trailing_comma_in_list, {:COMMA, ",", nil, {0, 0}}}} =
               Parser.parse(tokens)
    end

    test "missing comma" do
      tokens = [
        {:LEFT_PAREN, "(", nil, {0, 0}},
        {:STRING_VALUE, "'a'", "a", {0, 0}},
        {:STRING_VALUE, "'b'", "b", {0, 0}},
        {:RIGHT_PAREN, ")", nil, {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:missing_comma_in_list, {:STRING_VALUE, "'b'", "b", {0, 0}}}} =
               Parser.parse(tokens)
    end

    test "list not allowed" do
      tokens = [
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:LEFT_PAREN, "(", nil, {0, 0}},
        {:STRING_VALUE, "'a'", "a", {0, 0}},
        {:RIGHT_PAREN, ")", nil, {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:list_not_allowed_for_colon_op, {:LEFT_PAREN, "(", nil, {0, 0}}}} =
               Parser.parse(tokens)
    end

    test "invalid wildcard position" do
      tokens = [
        {:FIELD_IDENTIFIER, "title", "title", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        # bare, not quoted
        {:STRING_VALUE, "fo*o", "fo*o", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:invalid_wildcard_position, {:STRING_VALUE, "fo*o", "fo*o", {0, 0}}}} =
               Parser.parse(tokens)
    end

    test "wildcard with relop" do
      tokens = [
        {:FIELD_IDENTIFIER, "title", "title", {0, 0}},
        {:GREATER_THAN_COMPARATOR, ">", nil, {0, 0}},
        {:STRING_VALUE, "foo*", "foo*", {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:wildcard_not_allowed_for_relop, {:STRING_VALUE, "foo*", "foo*", {0, 0}}}} =
               Parser.parse(tokens)
    end

    test "IN list with bare wildcard" do
      tokens = [
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:SET_IN, "IN", :in, {0, 0}},
        {:LEFT_PAREN, "(", nil, {0, 0}},
        # bare wildcard -> illegal in list
        {:STRING_VALUE, "foo*", "foo*", {0, 0}},
        {:RIGHT_PAREN, ")", nil, {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:wildcard_not_allowed_in_list, {:STRING_VALUE, "foo*", "foo*", {0, 0}}}} =
               Parser.parse(tokens)

      ok = [
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:SET_IN, "IN", :in, {0, 0}},
        {:LEFT_PAREN, "(", nil, {0, 0}},
        {:STRING_VALUE, "'*foo'", "*foo", {0, 0}},
        {:COMMA, ",", nil, {0, 0}},
        {:STRING_VALUE, "'bar*'", "bar*", {0, 0}},
        {:RIGHT_PAREN, ")", nil, {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:ok, %AST.Cmp{op: :in, value: ["*foo", "bar*"]}} = Parser.parse(ok)
    end

    test "NOT must precede a term" do
      tokens = [{:NOT_MODIFIER, "NOT", nil, {0, 0}}, {:EOF, "", nil, {0, 0}}]

      assert {:error, {:not_without_term, {:NOT_MODIFIER, "NOT", nil, {0, 0}}}} =
               Parser.parse(tokens)
    end

    test "empty group" do
      tokens = [
        {:LEFT_PAREN, "(", nil, {0, 0}},
        {:RIGHT_PAREN, ")", nil, {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:empty_group, {:LEFT_PAREN, "(", nil, {0, 0}}}} = Parser.parse(tokens)
    end

    test "operated before right parenthesis" do
      tokens = [
        {:LEFT_PAREN, "(", nil, {0, 0}},
        {:FIELD_IDENTIFIER, "status", "status", {0, 0}},
        {:EQUALITY_COMPARATOR, ":", nil, {0, 0}},
        {:STRING_VALUE, "live", "live", {0, 0}},
        {:AND_CONNECTOR, "AND", "and", {0, 0}},
        {:RIGHT_PAREN, ")", nil, {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:operator_before_right_paren, {:AND_CONNECTOR, "AND", "and", {0, 0}}}} =
               Parser.parse(tokens)
    end

    test "stray comma" do
      tokens = [
        {:STRING_VALUE, "x", "x", {0, 0}},
        {:COMMA, ",", nil, {0, 0}},
        {:EOF, "", nil, {0, 0}}
      ]

      assert {:error, {:stray_comma, {:COMMA, ",", nil, {0, 0}}}} = Parser.parse(tokens)
    end
  end
end
