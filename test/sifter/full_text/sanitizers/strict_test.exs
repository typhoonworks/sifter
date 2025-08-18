defmodule Sifter.FullText.Sanitizers.StrictTest do
  use ExUnit.Case, async: true

  alias Sifter.FullText.Sanitizers.Strict

  describe "sanitize_tsquery/1" do
    test "allows normal alphanumeric terms" do
      result = Strict.sanitize_tsquery("validation system")
      assert result == "validation:* & system:*"
    end

    test "handles single valid term" do
      result = Strict.sanitize_tsquery("authentication")
      assert result == "authentication:*"
    end

    test "removes special characters and wildcards" do
      result = Strict.sanitize_tsquery("val%_ation sys-tem")
      assert result == "valation:* & system:*"
    end

    test "prevents SQL injection attempts" do
      result = Strict.sanitize_tsquery("'; DROP TABLE users; --")
      assert result == "DROP:* & TABLE:* & users:*"

      result = Strict.sanitize_tsquery("' UNION SELECT * FROM users --")
      assert result == "UNION:* & SELECT:* & FROM:* & users:*"
    end

    test "prevents PostgreSQL tsquery injection" do
      result = Strict.sanitize_tsquery("validation & !authentication")
      assert result == "validation:* & authentication:*"

      result = Strict.sanitize_tsquery("validation | authentication")
      assert result == "validation:* & authentication:*"
    end

    test "prevents wildcard attacks" do
      result = Strict.sanitize_tsquery("%._%")
      assert result == ""

      result = Strict.sanitize_tsquery("test.*")
      assert result == "test:*"
    end

    test "enforces minimum term length" do
      result = Strict.sanitize_tsquery("a b c validation")
      assert result == "validation:*"

      result = Strict.sanitize_tsquery("% _ -")
      assert result == ""
    end

    test "enforces maximum query length" do
      long_string = String.duplicate("abcdefghij ", 20)
      result = Strict.sanitize_tsquery(long_string)

      refute String.contains?(result, String.slice(long_string, 100, 10))
    end

    test "limits number of terms" do
      many_terms = Enum.join(1..15, " ")
      result = Strict.sanitize_tsquery(many_terms)

      term_count = String.split(result, " & ") |> length()
      assert term_count <= 5
    end

    test "handles empty and nil input" do
      assert Strict.sanitize_tsquery("") == ""
      assert Strict.sanitize_tsquery("   ") == ""
      assert Strict.sanitize_tsquery(nil) == ""
    end

    test "handles non-string input" do
      assert Strict.sanitize_tsquery(123) == ""
      assert Strict.sanitize_tsquery(%{}) == ""
    end

    test "preserves numbers in alphanumeric terms" do
      result = Strict.sanitize_tsquery("test123 user456")
      assert result == "test123:* & user456:*"
    end

    test "strips non-alphanumeric from mixed content" do
      result = Strict.sanitize_tsquery("user@domain.com test-case")
      assert result == "userdomaincom:* & testcase:*"
    end
  end

  describe "valid_search_query?/1" do
    test "validates non-empty sanitized queries" do
      assert Strict.valid_search_query?("validation:*")
      assert Strict.valid_search_query?("validation:* & system:*")
    end

    test "rejects empty queries" do
      refute Strict.valid_search_query?("")
      refute Strict.valid_search_query?("   ")
      refute Strict.valid_search_query?(nil)
    end

    test "rejects non-string input" do
      refute Strict.valid_search_query?(123)
      refute Strict.valid_search_query?(%{})
    end
  end

  describe "OWASP SQL wildcard attack prevention" do
    test "prevents percentage wildcard attacks" do
      malicious_queries = [
        "admin%",
        "%admin",
        "%admin%",
        "a%min",
        "a_min",
        "_dmin",
        "admin_"
      ]

      Enum.each(malicious_queries, fn query ->
        result = Strict.sanitize_tsquery(query)

        if result != "" do
          refute String.contains?(result, "%")
          refute String.contains?(result, "_")
        end
      end)
    end

    test "prevents complex wildcard combinations" do
      complex_attacks = [
        "a%b_c%d",
        "%_%_%",
        "[abc]%",
        "user[0-9]%",
        "admin' OR '1'='1",
        "test'; EXEC sp_addlogin 'hacker'"
      ]

      Enum.each(complex_attacks, fn attack ->
        result = Strict.sanitize_tsquery(attack)

        if result != "" do
          assert String.match?(result, ~r/^[a-zA-Z0-9:*& ]+$/)
        end
      end)
    end
  end

  describe "tsquery-specific attack prevention" do
    test "removes tsquery operators" do
      operators = ["&", "|", "!", "(", ")", "<", ">"]

      Enum.each(operators, fn op ->
        result = Strict.sanitize_tsquery("test#{op}validation")
        assert result == "testvalidation:*"
      end)
    end

    test "prevents query complexity attacks" do
      complex_query =
        String.duplicate("(test & ", 50) <> "validation" <> String.duplicate(")", 50)

      result = Strict.sanitize_tsquery(complex_query)

      assert String.match?(result, ~r/^[a-zA-Z0-9:*& ]+$/)
    end

    test "prevents phrase injection" do
      phrase_attacks = [
        "\"malicious phrase\"",
        "'single quoted'",
        "`backtick quoted`"
      ]

      Enum.each(phrase_attacks, fn attack ->
        result = Strict.sanitize_tsquery(attack)
        refute String.contains?(result, "\"")
        refute String.contains?(result, "'")
        refute String.contains?(result, "`")
      end)
    end

    test "prevents proximity operator attacks" do
      proximity_attacks = [
        "word1 <-> word2",
        "test <2> validation",
        "user NEAR admin"
      ]

      Enum.each(proximity_attacks, fn attack ->
        result = Strict.sanitize_tsquery(attack)

        if result != "" do
          assert String.match?(result, ~r/^[a-zA-Z0-9:*& ]+$/)
        end
      end)
    end
  end

  describe "edge cases and boundary conditions" do
    test "handles unicode and international characters" do
      result = Strict.sanitize_tsquery("café naïve résumé")
      assert result == "caf:* & nave:* & rsum:*"
    end

    test "handles mixed case" do
      result = Strict.sanitize_tsquery("TeSt CaSe")
      assert result == "TeSt:* & CaSe:*"
    end

    test "handles numbers only" do
      result = Strict.sanitize_tsquery("123 456789")
      assert result == "123:* & 456789:*"
    end

    test "rejects single character terms after cleaning" do
      result = Strict.sanitize_tsquery("a! b@ c# validation")
      assert result == "validation:*"
    end

    test "respects term limits with edge cases" do
      base_terms = Enum.map(1..10, &"term#{&1}") |> Enum.join(" ")
      extra_terms = " extra1 extra2 extra3"
      full_query = base_terms <> extra_terms

      result = Strict.sanitize_tsquery(full_query)
      term_count = String.split(result, " & ") |> length()

      assert term_count <= 5
    end
  end
end
