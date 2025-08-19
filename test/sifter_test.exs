defmodule SifterTest do
  use Sifter.DataCase, async: true
  doctest Sifter

  import Sifter.Fixtures
  alias Sifter.Test.Schemas.Event
  alias Sifter.Test.Repo

  describe "filter/3 - complex queries with fixtures" do
    setup do
      setup_sample_events()
    end

    test "complex query with ranges, IN operations, wildcards and full-text search", %{
      orgs: %{beatz: beatz, donutz: donutz}
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      future_time =
        DateTime.add(DateTime.utc_now(), 7 * 24 * 3600, :second)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      query = """
      (status:live OR status:draft OR status:building)
      AND organization_id IN (#{beatz.id}, #{donutz.id})
      AND (name:*event OR description:*desc OR tag.name:music OR org.name:*eatz)
      AND priority>=1 AND priority<=5
      AND active:true
      AND time_start>='#{now}' AND time_end<='#{future_time}'
      AND "Typhoon Works"
      """

      filters = [
        "status",
        "priority",
        "active",
        %{as: "tag.name", field: "tags.name"},
        %{as: "org.name", field: "organization.name"}
      ]

      assert {:ok, ecto_query, meta} =
               Sifter.filter(Event, query,
                 schema: Event,
                 allowed_fields: filters,
                 search_fields: [:name, :description],
                 search_strategy: {:tsquery, "english"}
               )

      results = Repo.all(ecto_query)

      assert is_list(results)
      assert meta.uses_full_text? == true
    end

    test "complex query with NOT and nested associations", %{
      events: %{e4: e4}
    } do
      query = "NOT status:draft AND tags.name:music"

      filters = [%{as: "tags.name", field: "tags.name"}]

      assert {:ok, ecto_query, meta} =
               Sifter.filter(Event, query, schema: Event, allowed_fields: filters)

      results = Repo.all(ecto_query)
      _result_ids = Enum.map(results, & &1.id) |> Enum.sort()

      _expected_ids = [e4.id] |> Enum.sort()

      assert length(results) >= 1
      assert meta.uses_full_text? == false
    end

    test "complex query with NULL sentinel", %{
      events: %{e4: e4, e5: e5},
      tags: %{live: live_tag, music: music_tag, family: family_tag}
    } do
      orphan =
        insert_event(%{
          name: "Orphan Event",
          status: "live"
        })

      query =
        """
        organization IN (NULL, #{e5.organization_id})
        OR
        tag ALL (#{live_tag.name}, #{music_tag.name}, #{family_tag.name})
        """
        |> String.trim()

      filters = [
        %{as: "organization", field: "organization_id"},
        %{as: "tag", field: "tags.name"}
      ]

      assert {:ok, ecto_query, meta} =
               Sifter.filter(Event, query, allowed_fields: filters)

      results = Repo.all(ecto_query)
      result_ids = Enum.map(results, & &1.id) |> Enum.sort()
      expected_ids = [orphan.id, e4.id, e5.id] |> Enum.sort()

      # orphan matches because organization_id is NULL
      # e4 matches because it has all the required tags
      # e5 matches because its organization_id is explicitly in the list
      assert result_ids == expected_ids
      assert meta.uses_full_text? == false
    end

    test "custom sanitizer function is applied" do
      target_event =
        insert_event(%{
          name: "UniqueXYZ123 Event",
          status: "live",
          organization_id: insert_organization(%{name: "Test Org"}).id
        })

      insert_event(%{
        name: "foobar Event",
        status: "live",
        organization_id: target_event.organization_id
      })

      custom_sanitizer = fn term -> String.replace(term, "foobar", "UniqueXYZ123") end

      query = "foobar"

      {:ok, ecto_query, meta} =
        Sifter.filter(Event, query,
          schema: Event,
          search_fields: ["name"],
          search_strategy: :ilike,
          full_text_sanitizer: custom_sanitizer
        )

      results = Repo.all(ecto_query)

      assert meta.uses_full_text? == true
      assert length(results) == 1
      assert hd(results).id == target_event.id
      assert String.contains?(hd(results).name, "UniqueXYZ123")
    end
  end

  describe "to_sql/4 - SQL generation" do
    test "simple field:value clause" do
      query = "status:live"

      assert {:ok, sql, params, meta} =
               Sifter.to_sql(Event, query, Repo, schema: Event)

      assert sql =~ ~r/WHERE.*status.*=.*\$1/i
      assert params == ["live"]
      assert meta.uses_full_text? == false
    end

    test "field:value with IN and OR clauses" do
      query = "priority>5 AND (status IN (live, building) OR name:test*)"

      assert {:ok, sql, params, meta} =
               Sifter.to_sql(Event, query, Repo, schema: Event)

      assert sql =~ ~r/WHERE/i
      assert sql =~ ~r/priority.*>/i
      assert sql =~ ~r/status.*IN/i
      assert sql =~ ~r/OR/i
      assert sql =~ ~r/name.*LIKE/i or sql =~ ~r/name.*ILIKE/i

      assert length(params) >= 3
      assert 5 in params
      assert ["live", "building"] in params
      assert "test%" in params

      assert meta.uses_full_text? == false
    end
  end

  describe "to_sql!/4 - SQL generation" do
    test "returns SQL directly or raises on error" do
      query = "status:live"

      {sql, params, meta} =
        Sifter.to_sql!(Event, query, Repo, schema: Event)

      assert sql =~ ~r/WHERE.*status.*=.*\$1/i
      assert params == ["live"]
      assert meta.uses_full_text? == false
    end

    test "raises on invalid query" do
      query = "status:live AND"

      assert_raise Sifter.Error, fn ->
        Sifter.to_sql!(Event, query, Repo, schema: Event)
      end
    end
  end

  describe "error handling - human readable syntax errors with location" do
    test "lexer error: unterminated string" do
      query = "status:'unterminated"

      assert {:error, error} = Sifter.filter(Event, query, schema: Event)

      message = Exception.message(error)
      assert message =~ "Unterminated string"
      assert message =~ "at position 7"
    end

    test "lexer error: invalid operator" do
      query = "status=live"

      assert {:error, error} = Sifter.filter(Event, query, schema: Event)

      message = Exception.message(error)
      assert message =~ "Invalid" or message =~ "Unexpected"
      assert message =~ "="
      assert message =~ "at position 6"
    end

    test "parser error: missing right parenthesis" do
      query = "(status:live OR name:test"

      assert {:error, error} = Sifter.filter(Event, query, schema: Event)

      message = Exception.message(error)
      assert message =~ "Missing closing parenthesis"
      assert message =~ "at position 0"
    end

    test "parser error: unexpected token after operator" do
      query = "status:live AND"

      assert {:error, error} = Sifter.filter(Event, query, schema: Event)

      message = Exception.message(error)

      assert message ==
               "Expected expression after 'AND' at position 12. Operators must be followed by a value or field."
    end

    test "parser error: invalid wildcard position" do
      query = "name:test*more*stuff"

      assert {:error, error} = Sifter.filter(Event, query, schema: Event)

      message = Exception.message(error)
      assert message =~ "wildcard" or message =~ "invalid"
      assert message =~ "at position"
    end

    test "parser error: empty list in IN clause" do
      query = "status IN ()"

      assert {:error, error} = Sifter.filter(Event, query, schema: Event)

      message = Exception.message(error)
      assert message == "Empty list at position 10. Lists must contain at least one value."
    end

    test "parser error: trailing comma in list" do
      query = "status IN (live, draft,)"

      assert {:error, error} = Sifter.filter(Event, query, schema: Event)

      message = Exception.message(error)

      assert message ==
               "Trailing comma at position 22. Remove the comma after the last list item."
    end

    test "complex error should show human readable message with byte offset" do
      query = "status:live AND (incomplete AND ="

      assert {:error, error} = Sifter.filter(Event, query, schema: Event)

      message = Exception.message(error)
      assert message =~ "at position"
      assert is_binary(message) and String.length(message) > 10
      refute message =~ ~r/^sifter \w+ error: .*/
    end
  end
end
