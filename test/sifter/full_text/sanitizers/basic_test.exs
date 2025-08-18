defmodule Sifter.FullText.Sanitizers.BasicTest do
  use ExUnit.Case, async: true

  alias Sifter.FullText.Sanitizers.Basic

  describe "sanitize_plainto/1" do
    test "preserves normal search terms" do
      result = Basic.sanitize_plainto("validation system")
      assert result == "validation system"
    end

    test "handles single term" do
      result = Basic.sanitize_plainto("authentication")
      assert result == "authentication"
    end

    test "trims whitespace" do
      result = Basic.sanitize_plainto("  validation system  ")
      assert result == "validation system"
    end

    test "collapses multiple spaces" do
      result = Basic.sanitize_plainto("validation    system   testing")
      assert result == "validation system testing"
    end

    test "handles various whitespace characters" do
      result = Basic.sanitize_plainto("validation\t\n\r  system")
      assert result == "validation system"
    end

    test "enforces length limit" do
      long_string = String.duplicate("a", 120)
      result = Basic.sanitize_plainto(long_string)

      assert String.length(result) == 100
      assert result == String.duplicate("a", 100)
    end

    test "preserves special characters (safe for plainto_tsquery)" do
      result = Basic.sanitize_plainto("validation & system | test")
      assert result == "validation & system | test"
    end

    test "preserves punctuation" do
      result = Basic.sanitize_plainto("user@example.com test-case")
      assert result == "user@example.com test-case"
    end

    test "handles empty and nil input" do
      assert Basic.sanitize_plainto("") == ""
      assert Basic.sanitize_plainto("   ") == ""
      assert Basic.sanitize_plainto(nil) == ""
    end

    test "handles non-string input" do
      assert Basic.sanitize_plainto(123) == ""
      assert Basic.sanitize_plainto(%{}) == ""
      assert Basic.sanitize_plainto([]) == ""
    end

    test "handles mixed content with length limit" do
      mixed_content = "validation    " <> String.duplicate("test ", 20) <> "   system"
      result = Basic.sanitize_plainto(mixed_content)

      assert String.length(result) <= 100
      refute String.contains?(result, "    ")
    end

    test "preserves international characters" do
      result = Basic.sanitize_plainto("café naïve résumé")
      assert result == "café naïve résumé"
    end

    test "handles newlines and tabs" do
      result = Basic.sanitize_plainto("line1\nline2\tword")
      assert result == "line1 line2 word"
    end
  end

  describe "edge cases for plainto_tsquery safety" do
    test "allows SQL-like content (safe with plainto_tsquery)" do
      sql_like = "SELECT * FROM users WHERE id = 1"
      result = Basic.sanitize_plainto(sql_like)
      assert result == "SELECT * FROM users WHERE id = 1"
    end

    test "allows tsquery operators (safe with plainto_tsquery)" do
      tsquery_ops = "validation & system | !test"
      result = Basic.sanitize_plainto(tsquery_ops)
      assert result == "validation & system | !test"
    end

    test "allows wildcards (safe with plainto_tsquery)" do
      wildcards = "test% _wildcard"
      result = Basic.sanitize_plainto(wildcards)
      assert result == "test% _wildcard"
    end
  end
end
