defmodule Sifter.BuilderTest do
  use Sifter.DataCase, async: true

  alias Sifter.Test.Repo
  alias Sifter.Test.Schemas.Event
  alias Sifter.Ecto.Builder
  alias Sifter.AST

  import Sifter.Fixtures
  import Ecto.Query

  defp to_sql!(%Ecto.Query{} = q),
    do: Ecto.Adapters.SQL.to_sql(:all, Repo, q)

  defp parse!(s) do
    {:ok, toks} = Sifter.Query.Lexer.tokenize(s)
    {:ok, ast} = Sifter.Query.Parser.parse(toks)
    ast
  end

  describe "blank AST (no predicates)" do
    test "with base = Event → returns all events; no WHERE added" do
      e1 = insert_event(%{status: "draft"})
      e2 = insert_event(%{status: "live"})
      e3 = insert_event(%{status: "building"})

      ast = parse!("")

      assert {:ok, :no_predicates, q} =
               Builder.apply(Event, ast, schema: Event, search_fields: [])

      rows = Repo.all(q)

      assert Enum.sort(Enum.map(rows, & &1.id)) ==
               Enum.sort([e1.id, e2.id, e3.id])

      {sql, _params} = to_sql!(q)
      refute sql =~ "WHERE"
    end

    test "with base = from e in Event, where: e.status == \"draft\" → unchanged subset" do
      d1 = insert_event(%{status: "draft"})
      _l1 = insert_event(%{status: "live"})
      d2 = insert_event(%{status: "draft"})

      base = from(e in Event, where: e.status == "draft")
      ast = %AST.And{children: []}

      assert {:ok, :no_predicates, ^base} =
               Builder.apply(base, ast, schema: Event, search_fields: [])

      rows = Repo.all(base)

      assert Enum.sort(Enum.map(rows, & &1.id)) ==
               Enum.sort([d1.id, d2.id])

      {sql0, params0} = to_sql!(base)

      {:ok, :no_predicates, qb} = Builder.apply(base, ast, schema: Event, search_fields: [])
      {sql1, params1} = to_sql!(qb)

      assert sql1 == sql0
      assert params1 == params0
    end
  end

  describe "when filters are not provided" do
    test "nodes targeting existing columns" do
      e = insert_event(%{status: "draft", name: "ABC"})
      ast = parse!("status:draft")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      assert rows == [e]

      {sql, params} = to_sql!(q)
      assert sql =~ "WHERE"
      assert "draft" in params
    end

    test "nodes targeting non-existing columns are ignored" do
      e = insert_event()
      ast = parse!("invalid:abc")

      assert {:ok, :no_predicates, q} =
               Builder.apply(Event, ast, schema: Event, search_fields: [])

      rows = Repo.all(q)
      assert Enum.any?(rows, &(&1.id == e.id))

      {sql, _params} = to_sql!(q)
      refute sql =~ "WHERE"
    end

    test "mix of supported and unsupported " do
      e1 = insert_event(%{status: "draft", name: "ABC"})
      _e2 = insert_event(%{status: "live", name: "ABC"})

      ast = parse!("status:draft AND invalid:whatever")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      assert rows == [e1]

      {sql, params} = to_sql!(q)
      assert sql =~ "WHERE"
      assert "draft" in params
    end

    test "unknown field returns error when unknown_field: :error or mode: :strict" do
      _e = insert_event()

      ast = parse!("status:draft AND invalid:whatever")

      assert {:error, {:builder, {:unknown_field, "invalid"}}} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: [],
                 unknown_field: :error
               )

      assert {:error, {:builder, {:unknown_field, "invalid"}}} =
               Builder.apply(Event, ast, schema: Event, search_fields: [], mode: :strict)
    end

    test "unknown field returns warning and still applies supported predicates" do
      e1 = insert_event(%{status: "draft"})
      _e2 = insert_event(%{status: "live"})

      ast = parse!("status:draft AND invalid:whatever")

      assert {:ok, q, meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: [],
                 unknown_field: :warn
               )

      rows = Repo.all(q)
      assert rows == [e1]

      assert is_list(meta[:warnings])

      assert Enum.any?(meta.warnings, fn w ->
               w[:type] == :unknown_field and w[:path] == "invalid"
             end)
    end
  end

  describe "when filters are provided (allow-list)" do
    test "supported filter applies" do
      d = insert_event(%{status: "draft"})
      _l = insert_event(%{status: "live"})

      ast = parse!("status:draft")

      assert {:ok, q, _meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: [],
                 allowed_fields: ["status"]
               )

      rows = Repo.all(q)
      assert rows == [d]

      {sql, params} = to_sql!(q)
      assert sql =~ "WHERE"
      assert "draft" in params
    end

    test "unsupported filter is ignored by default (lenient)" do
      e1 = insert_event(%{name: "ABC"})
      e2 = insert_event(%{name: "XYZ"})

      ast = parse!("name:ABC")

      assert {:ok, :no_predicates, q} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: [],
                 allowed_fields: ["status"]
               )

      rows = Repo.all(q)
      assert Enum.sort(Enum.map(rows, & &1.id)) == Enum.sort([e1.id, e2.id])

      {sql, _params} = to_sql!(q)
      refute sql =~ "WHERE"
    end

    test "unsupported filter errors in strict mode" do
      _ = insert_event(%{name: "ABC"})
      ast = parse!("name:ABC")

      assert {:error, {:builder, {:unknown_field, "name"}}} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: [],
                 allowed_fields: ["status"],
                 unknown_field: :error
               )
    end

    test "alias mapping: alias works, original rejected (lenient ignored)" do
      d = insert_event(%{status: "draft"})
      l = insert_event(%{status: "live"})

      filters = [%{as: "event.status", field: "status"}]

      ast_ok = parse!("event.status:draft")

      assert {:ok, q1, _meta1} =
               Builder.apply(Event, ast_ok,
                 schema: Event,
                 search_fields: [],
                 allowed_fields: filters
               )

      assert Repo.all(q1) == [d]

      ast_bad = parse!("status:draft")

      assert {:ok, :no_predicates, q2} =
               Builder.apply(Event, ast_bad,
                 schema: Event,
                 search_fields: [],
                 allowed_fields: filters
               )

      rows2 = Repo.all(q2)
      assert Enum.sort(Enum.map(rows2, & &1.id)) == Enum.sort([d.id, l.id])
    end
  end

  describe "joins via dotted paths" do
    test "lenient (no filters provided): status + organization.name starts_with" do
      org1 = insert_organization(%{name: "Beatz"})
      org2 = insert_organization(%{name: "Donutz"})

      live_beatz = insert_event(%{status: "live", organization_id: org1.id})
      _live_donut = insert_event(%{status: "live", organization_id: org2.id})
      _draft_beatz = insert_event(%{status: "draft", organization_id: org1.id})

      ast = parse!("status:live AND organization.name:Bea*")

      assert {:ok, q, _meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: []
               )

      rows = Repo.all(q)
      assert rows == [live_beatz]

      {sql, _params} = to_sql!(q)
      assert sql =~ "JOIN"
    end

    test "allow-list: join path must be explicitly allowed" do
      org1 = insert_organization(%{name: "Beatz"})
      org2 = insert_organization(%{name: "Donutz"})

      live_beatz = insert_event(%{status: "live", organization_id: org1.id})
      live_donut = insert_event(%{status: "live", organization_id: org2.id})

      ast = parse!("status:live AND organization.name:Bea*")

      assert {:ok, q_ignored, _meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: [],
                 allowed_fields: ["status"]
               )

      rows_ignored = Repo.all(q_ignored)

      assert Enum.sort(Enum.map(rows_ignored, & &1.id)) ==
               Enum.sort([live_beatz.id, live_donut.id])

      {sql_ignored, _} = to_sql!(q_ignored)
      refute sql_ignored =~ "JOIN"

      assert {:ok, q_ok, _meta2} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: [],
                 allowed_fields: ["status", "organization.name"]
               )

      rows_ok = Repo.all(q_ok)
      assert rows_ok == [live_beatz]

      {sql_ok, _} = to_sql!(q_ok)
      assert sql_ok =~ "JOIN"
    end

    test "allow-list strict: unknown dotted path errors" do
      _org = insert_organization(%{name: "Beatz"})
      _evt = insert_event(%{status: "live"})

      ast = parse!("status:live AND organization.name:Bea*")

      assert {:error, {:builder, {:unknown_field, "organization.name"}}} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: [],
                 allowed_fields: ["status"],
                 unknown_field: :error
               )
    end

    test "alias for dotted path works; original rejected" do
      org1 = insert_organization(%{name: "Beatz"})
      org2 = insert_organization(%{name: "Donutz"})
      e1 = insert_event(%{status: "live", organization_id: org1.id})
      e2 = insert_event(%{status: "live", organization_id: org2.id})

      filters = [
        %{as: "org.name", field: "organization.name"},
        "status"
      ]

      ast_alias = parse!("status:live AND org.name:Bea*")

      assert {:ok, q1, _} =
               Builder.apply(Event, ast_alias,
                 schema: Event,
                 search_fields: [],
                 allowed_fields: filters
               )

      assert Repo.all(q1) == [e1]

      ast_orig = parse!("status:live AND organization.name:Bea*")

      assert {:ok, q2, _} =
               Builder.apply(Event, ast_orig,
                 schema: Event,
                 search_fields: [],
                 allowed_fields: filters
               )

      ids2 = Repo.all(q2) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids2 == Enum.sort([e1.id, e2.id])
    end
  end

  describe "comparison operators" do
    setup do
      # Create test data with different values for numeric/date comparisons
      e1 = insert_event(%{status: "live", priority: 1})
      e2 = insert_event(%{status: "live", priority: 5})
      e3 = insert_event(%{status: "live", priority: 10})
      e4 = insert_event(%{status: "draft", priority: 3})

      %{events: [e1, e2, e3, e4]}
    end

    test "equality operator (:)", %{events: [_e1, e2, _e3, _e4]} do
      ast = parse!("priority:5")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      assert rows == [e2]
    end

    test "less than operator (<)", %{events: [e1, _e2, _e3, e4]} do
      ast = parse!("priority<5")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([e1.id, e4.id])
    end

    test "less than or equal operator (<=)", %{events: [e1, e2, _e3, e4]} do
      ast = parse!("priority<=5")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([e1.id, e2.id, e4.id])
    end

    test "greater than operator (>)", %{events: [_e1, _e2, e3, _e4]} do
      ast = parse!("priority>5")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      assert rows == [e3]
    end

    test "greater than or equal operator (>=)", %{events: [_e1, e2, e3, _e4]} do
      ast = parse!("priority>=5")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([e2.id, e3.id])
    end

    test "comparison with quoted values" do
      _e1 = insert_event(%{name: "Event A"})
      e2 = insert_event(%{name: "Event Z"})

      ast = parse!("name>'Event M'")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      assert rows == [e2]
    end
  end

  describe "wildcard patterns" do
    setup do
      org1 = insert_organization(%{name: "Acme Corp"})
      org2 = insert_organization(%{name: "Beta Inc"})
      org3 = insert_organization(%{name: "Corp Gamma"})

      e1 = insert_event(%{status: "live", organization_id: org1.id})
      e2 = insert_event(%{status: "live", organization_id: org2.id})
      e3 = insert_event(%{status: "live", organization_id: org3.id})

      %{events: [e1, e2, e3], orgs: [org1, org2, org3]}
    end

    test "prefix wildcard (starts_with) - field:value*", %{events: [e1, _e2, _e3]} do
      ast = parse!("organization.name:Acme*")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      assert rows == [e1]

      {sql, params} = to_sql!(q)
      assert sql =~ "LIKE" or sql =~ "ILIKE"
      assert Enum.any?(params, &String.starts_with?(&1, "Acme"))
    end

    test "suffix wildcard (ends_with) - field:*value", %{events: [e1, _e2, _e3]} do
      ast = parse!("organization.name:*Corp")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()
      assert ids == [e1.id]

      {sql, params} = to_sql!(q)
      assert sql =~ "LIKE" or sql =~ "ILIKE"
      assert Enum.any?(params, &String.ends_with?(&1, "Corp"))
    end

    test "quoted wildcard treated as literal", %{events: [_e1, _e2, _e3]} do
      org_literal = insert_organization(%{name: "Test*Corp"})
      e_literal = insert_event(%{status: "live", organization_id: org_literal.id})

      ast = parse!("organization.name:'Test*Corp'")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      assert rows == [e_literal]

      {_sql, params} = to_sql!(q)
      assert "Test*Corp" in params
    end

    test "wildcards on root fields" do
      _e1 = insert_event(%{name: "Project Alpha"})
      e2 = insert_event(%{name: "Alpha Beta"})
      _e3 = insert_event(%{name: "Gamma Project"})

      ast = parse!("name:Alpha*")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      assert rows == [e2]
    end
  end

  describe "set operations (IN / NOT IN)" do
    setup do
      e1 = insert_event(%{status: "live"})
      e2 = insert_event(%{status: "draft"})
      e3 = insert_event(%{status: "building"})
      e4 = insert_event(%{status: "archived"})

      %{events: [e1, e2, e3, e4]}
    end

    test "IN with multiple values", %{events: [e1, e2, _e3, _e4]} do
      ast = parse!("status IN ('live', 'draft')")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([e1.id, e2.id])

      {sql, params} = to_sql!(q)
      assert sql =~ "ANY" or sql =~ "IN"

      assert Enum.any?(params, fn p ->
               (is_list(p) and "live" in p and "draft" in p) or
                 (is_binary(p) and p in ["live", "draft"])
             end)
    end

    test "NOT IN excludes specified values", %{events: [_e1, _e2, e3, e4]} do
      ast = parse!("status NOT IN ('live', 'draft')")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([e3.id, e4.id])

      {sql, params} = to_sql!(q)
      assert (sql =~ "NOT" and sql =~ "ANY") or (sql =~ "NOT" and sql =~ "IN")

      assert Enum.any?(params, fn p ->
               (is_list(p) and "live" in p and "draft" in p) or
                 (is_binary(p) and p in ["live", "draft"])
             end)
    end

    test "IN with single value (edge case)" do
      e1 = insert_event(%{status: "live", name: "Live Event"})
      _e2 = insert_event(%{status: "draft", name: "Draft Event"})

      ast = parse!("status IN ('live')")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      assert e1 in rows
      assert Enum.all?(rows, &(&1.status == "live"))
    end

    test "IN with dotted paths" do
      org1 = insert_organization(%{name: "Acme"})
      org2 = insert_organization(%{name: "Beta"})
      org3 = insert_organization(%{name: "Gamma"})

      e1 = insert_event(%{organization_id: org1.id})
      e2 = insert_event(%{organization_id: org2.id})
      _e3 = insert_event(%{organization_id: org3.id})

      ast = parse!("organization.name IN ('Acme', 'Beta')")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([e1.id, e2.id])

      {sql, _params} = to_sql!(q)
      assert sql =~ "JOIN"
      assert sql =~ "ANY" or sql =~ "IN"
    end

    test "IN with numeric values" do
      e1 = insert_event(%{priority: 1})
      e2 = insert_event(%{priority: 5})
      _e3 = insert_event(%{priority: 10})

      ast = parse!("priority IN ('1', '5')")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([e1.id, e2.id])
    end
  end

  describe "boolean logic and precedence" do
    setup do
      e1 = insert_event(%{status: "live", priority: 1})
      e2 = insert_event(%{status: "live", priority: 10})
      e3 = insert_event(%{status: "draft", priority: 1})
      e4 = insert_event(%{status: "draft", priority: 10})

      %{events: [e1, e2, e3, e4]}
    end

    test "AND operator combines predicates", %{events: [e1, _e2, _e3, _e4]} do
      ast = parse!("status:live AND priority:1")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      assert rows == [e1]
    end

    test "OR operator creates alternatives", %{events: [e1, _e2, _e3, e4]} do
      ast = parse!("status:live OR priority:10")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()
      assert length(rows) >= 3
      assert e1.id in ids
      assert e4.id in ids
    end

    test "implicit AND between terms", %{events: [e1, _e2, _e3, _e4]} do
      ast = parse!("status:live priority:1")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      assert rows == [e1]
    end

    test "AND has higher precedence than OR: A OR B AND C", %{events: [e1, e2, e3, e4]} do
      ast = parse!("status:live OR status:draft AND priority:10")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()
      # live, priority 1
      assert e1.id in ids
      # live, priority 10
      assert e2.id in ids
      # draft, priority 10
      assert e4.id in ids
      # draft, priority 1 should NOT match
      refute e3.id in ids
    end

    test "parentheses override precedence: (A OR B) AND C", %{events: [_e1, e2, _e3, e4]} do
      ast = parse!("(status:live OR status:draft) AND priority:10")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()
      expected_ids = [e2.id, e4.id] |> Enum.sort()
      assert ids == expected_ids
    end

    test "multiple ANDs and ORs" do
      e1 = insert_event(%{status: "live", priority: 1})
      e2 = insert_event(%{status: "live", priority: 5})
      e3 = insert_event(%{status: "draft", priority: 1})
      e4 = insert_event(%{status: "building", priority: 1})

      ast = parse!("status:live OR status:draft OR status:building AND priority:1")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()
      # Should match: all live, all draft, and building with priority 1
      # live
      assert e1.id in ids
      # live
      assert e2.id in ids
      # draft
      assert e3.id in ids
      # building with priority 1
      assert e4.id in ids
    end

    test "complex query with parentheses, IN operations, wildcards, and range comparisons - reproduces SifterTest issue" do
      beatz = insert_organization(%{name: "Beatz"})
      donutz = insert_organization(%{name: "Donutz"})

      _e1 =
        insert_event(%{
          status: "live",
          organization_id: beatz.id,
          name: "Test Event",
          priority: 3,
          active: true
        })

      _e2 =
        insert_event(%{
          status: "draft",
          organization_id: donutz.id,
          name: "Another Event",
          priority: 2,
          active: true
        })

      query_str = """
      (status:live OR status:draft OR status:building)
      AND organization_id IN (#{beatz.id}, #{donutz.id})
      AND (name:*event OR description:*desc OR tag.name:music OR org.name:*eatz)
      AND priority>=1 AND priority<=5
      AND active:true
      AND time_start>='2024-01-01T00:00:00Z' AND time_end<='2025-01-01T00:00:00Z'
      AND "Typhoon Works"
      """

      ast = parse!(String.trim(query_str))

      filters = [
        "status",
        "priority",
        "active",
        %{as: "tag.name", field: "tags.name"},
        %{as: "org.name", field: "organization.name"}
      ]

      assert {:ok, q, meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 allowed_fields: filters,
                 search_fields: [:name, :description],
                 search_strategy: {:tsquery, "english"}
               )

      rows = Repo.all(q)
      assert is_list(rows)
      assert meta.uses_full_text? == true
    end
  end

  describe "NOT modifier" do
    setup do
      e1 = insert_event(%{status: "live"})
      e2 = insert_event(%{status: "draft"})
      e3 = insert_event(%{status: "building"})

      %{events: [e1, e2, e3]}
    end

    test "NOT before field predicate", %{events: [_e1, e2, e3]} do
      ast = parse!("NOT status:live")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([e2.id, e3.id])
    end

    test "dash NOT (-) before field predicate", %{events: [_e1, e2, e3]} do
      ast = parse!("-status:live")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([e2.id, e3.id])
    end

    test "NOT before grouped expression", %{events: [e1, _e2, _e3]} do
      ast = parse!("NOT (status:draft OR status:building)")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      assert rows == [e1]
    end

    test "NOT with AND/OR combinations", %{events: [_e1, _e2, e3]} do
      ast = parse!("NOT status:live AND status:building")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      assert rows == [e3]
    end

    test "NOT with comparison operators" do
      e1 = insert_event(%{priority: 1})
      e2 = insert_event(%{priority: 5})
      _e3 = insert_event(%{priority: 10})

      ast = parse!("NOT priority>5")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([e1.id, e2.id])
    end

    test "NOT with IN/NOT IN operations" do
      e1 = insert_event(%{status: "live"})
      e2 = insert_event(%{status: "draft"})
      e3 = insert_event(%{status: "building"})
      _e4 = insert_event(%{status: "archived"})

      ast = parse!("NOT status IN ('live', 'draft')")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()
      assert e3.id in ids
      refute e1.id in ids
      refute e2.id in ids
    end
  end

  describe "full-text search" do
    setup do
      e1 = insert_event(%{name: "Important meeting"})
      e2 = insert_event(%{name: "Team standup", description: "Daily sync meeting"})
      e3 = insert_event(%{name: "Code review", description: "Review pull requests"})

      %{events: [e1, e2, e3]}
    end

    test "bare term performs full-text search", %{events: [e1, e2, _e3]} do
      ast = parse!("meeting")

      assert {:ok, q, meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: ["name", "description"],
                 search_strategy: :ilike
               )

      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([e1.id, e2.id])

      assert meta.uses_full_text? == true
    end

    test "quoted full-text term", %{events: [_e1, e2, _e3]} do
      ast = parse!("\"Daily sync\"")

      assert {:ok, q, meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: ["name", "description"],
                 search_strategy: :ilike
               )

      rows = Repo.all(q)
      assert rows == [e2]
      assert meta.uses_full_text? == true
    end

    test "full-text with field predicates", %{events: [e1, _e2, _e3]} do
      _live_event = insert_event(%{status: "live", name: "Project update"})
      ast = parse!("status:live OR meeting")

      assert {:ok, q, meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: ["name", "description"],
                 search_strategy: :ilike
               )

      rows = Repo.all(q)
      assert length(rows) >= 2
      assert e1.id in Enum.map(rows, & &1.id)
      assert meta.uses_full_text? == true
    end

    test "full-text across associated fields" do
      org = insert_organization(%{name: "Tech Corp"})
      e1 = insert_event(%{name: "Meeting", organization_id: org.id})
      _e2 = insert_event(%{name: "Standup"})

      ast = parse!("Tech")

      assert {:ok, q, meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: ["name", "organization.name"],
                 search_strategy: :ilike
               )

      rows = Repo.all(q)
      assert rows == [e1]
      assert meta.uses_full_text? == true

      {sql, _params} = to_sql!(q)
      assert sql =~ "JOIN"
    end

    test "full-text with no configured fields returns no results" do
      _e1 = insert_event(%{name: "Important meeting"})

      ast = parse!("meeting")

      assert {:ok, :no_predicates, q} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: []
               )

      {sql, _params} = to_sql!(q)
      refute sql =~ "WHERE"
    end

    test "multiple full-text terms with AND", %{events: [_e1, e2, _e3]} do
      ast = parse!("Daily sync")

      assert {:ok, q, meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: ["name", "description"],
                 search_strategy: :ilike
               )

      rows = Repo.all(q)
      assert rows == [e2]
      assert meta.uses_full_text? == true
    end
  end

  describe "full-text search with tsvector strategy" do
    setup do
      e1 = insert_event(%{name: "Important meeting", description: "Weekly team sync"})
      e2 = insert_event(%{name: "Code review session", description: "Review pull requests"})
      e3 = insert_event(%{name: "Sprint planning", description: "Plan next sprint goals"})

      %{events: [e1, e2, e3]}
    end

    test "bare term with tsquery strategy using to_tsvector on fields", %{events: [e1, _e2, _e3]} do
      ast = parse!("meeting")

      assert {:ok, q, meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: ["name", "description"],
                 search_strategy: {:tsquery, "english"}
               )

      rows = Repo.all(q)
      assert e1.id in Enum.map(rows, & &1.id)
      assert meta.uses_full_text? == true

      {sql, _params} = to_sql!(q)
      assert sql =~ "to_tsvector"
      assert sql =~ "plainto_tsquery"
    end

    test "bare term with dedicated tsvector column strategy", %{events: [e1, _e2, _e3]} do
      ast = parse!("meeting")

      assert {:ok, q, meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: ["name", "description"],
                 search_strategy: {:column, {"english", :searchable}}
               )

      rows = Repo.all(q)
      assert e1.id in Enum.map(rows, & &1.id)
      assert meta.uses_full_text? == true
      assert meta.added_select_fields == [:search_rank]
      assert meta.recommended_order == [search_rank: :desc]

      {sql, params} = to_sql!(q)
      assert sql =~ "@@ plainto_tsquery"
      assert "meeting" in params
    end

    test "quoted phrase with tsvector column", %{events: [_e1, e2, _e3]} do
      ast = parse!("\"code review\"")

      assert {:ok, q, meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: ["name", "description"],
                 search_strategy: {:column, {"english", :searchable}}
               )

      rows = Repo.all(q)
      assert e2.id in Enum.map(rows, & &1.id)
      assert meta.uses_full_text? == true
    end

    test "multiple terms with tsquery strategy", %{events: [_e1, e2, _e3]} do
      ast = parse!("code review")

      assert {:ok, q, meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: ["name", "description"],
                 search_strategy: {:tsquery, "english"}
               )

      rows = Repo.all(q)
      assert e2.id in Enum.map(rows, & &1.id)
      assert meta.uses_full_text? == true
    end

    test "full-text with field predicates using tsvector", %{events: [_e1, _e2, e3]} do
      live_event = insert_event(%{status: "live", name: "Sprint meeting"})

      ast = parse!("status:live OR sprint")

      assert {:ok, q, meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: ["name", "description"],
                 search_strategy: {:column, {"english", :searchable}}
               )

      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id)
      assert live_event.id in ids
      assert e3.id in ids
      assert meta.uses_full_text? == true
    end

    test "tsvector strategy with associated fields" do
      org = insert_organization(%{name: "Tech Corp"})
      event = insert_event(%{name: "Meeting", organization_id: org.id})

      ast = parse!("tech")

      assert {:ok, q, meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: ["name", "organization.name"],
                 search_strategy: {:tsquery, "english"}
               )

      rows = Repo.all(q)
      assert event.id in Enum.map(rows, & &1.id)
      assert meta.uses_full_text? == true

      {sql, _params} = to_sql!(q)
      assert sql =~ "JOIN"
      assert sql =~ "to_tsvector"
    end

    test "complex boolean logic with tsvector", %{events: [e1, e2, e3]} do
      ast = parse!("(meeting OR review) AND NOT sprint")

      assert {:ok, q, meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: ["name", "description"],
                 search_strategy: {:column, {"english", :searchable}}
               )

      rows = Repo.all(q)
      ids = Enum.map(rows, & &1.id) |> Enum.sort()

      # Should include meeting (e1) and review (e2) but exclude sprint (e3)
      assert e1.id in ids
      assert e2.id in ids
      refute e3.id in ids
      assert meta.uses_full_text? == true
    end

    test "edge case: empty tsvector search returns no results" do
      ast = parse!("nonexistentword")

      assert {:ok, q, meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: ["name", "description"],
                 search_strategy: {:column, {"english", :searchable}}
               )

      rows = Repo.all(q)
      assert rows == []
      assert meta.uses_full_text? == true
    end

    test "tsvector strategy falls back when no fields configured" do
      ast = parse!("meeting")

      assert {:ok, :no_predicates, q} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: []
               )

      {sql, _params} = to_sql!(q)
      refute sql =~ "WHERE"
      refute sql =~ "tsvector"
    end
  end

  describe "type casting and validation" do
    test "numeric fields cast string values to appropriate types" do
      e1 = insert_event(%{priority: 5})
      e2 = insert_event(%{priority: 10})

      ast = parse!("priority:5")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      assert rows == [e1]

      ast2 = parse!("priority>5")
      assert {:ok, q2, _meta} = Builder.apply(Event, ast2, schema: Event, search_fields: [])
      rows2 = Repo.all(q2)
      assert rows2 == [e2]
    end

    test "date fields handle ISO date strings" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      past = NaiveDateTime.add(now, -3600, :second)
      future = NaiveDateTime.add(now, 3600, :second)

      e1 = insert_event(%{inserted_at: past})
      _e2 = insert_event(%{inserted_at: future})

      now_str = NaiveDateTime.to_iso8601(now)

      ast = parse!("inserted_at<'#{now_str}'")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      assert rows == [e1]
    end

    test "boolean fields handle string representations" do
      e1 = insert_event(%{active: true})
      _e2 = insert_event(%{active: false})

      ast = parse!("active:true")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)

      assert length(rows) >= 1
      assert e1.id in Enum.map(rows, & &1.id)
    end
  end

  describe "edge cases and error handling" do
    test "empty list in IN operation handled gracefully" do
      _e1 = insert_event(%{status: "live"})

      # This might be prevented at the parser level, but test builder resilience
      ast = %AST.Cmp{field_path: ["status"], op: :in, value: []}

      result = Builder.apply(Event, ast, schema: Event, search_fields: [])

      case result do
        {:ok, q, _meta} ->
          rows = Repo.all(q)
          assert rows == []

        {:error, _} ->
          :ok
      end
    end

    test "very deeply nested boolean expressions" do
      e1 = insert_event(%{status: "live", priority: 1})

      deep_ast = %AST.And{
        children: [
          %AST.Or{
            children: [
              %AST.And{
                children: [
                  %AST.Cmp{field_path: ["status"], op: :eq, value: "live"},
                  %AST.Cmp{field_path: ["priority"], op: :eq, value: "1"}
                ]
              }
            ]
          }
        ]
      }

      assert {:ok, q, _meta} = Builder.apply(Event, deep_ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      assert rows == [e1]
    end

    test "mixed valid/invalid fields in complex expressions" do
      e1 = insert_event(%{status: "live", priority: 1})
      e2 = insert_event(%{status: "live", priority: 2})
      e3 = insert_event(%{status: "draft", priority: 1})

      ast = parse!("status:live AND (invalid_field:whatever OR priority:1)")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)

      assert e1 in rows
      assert e2 not in rows
      assert e3 not in rows
    end

    test "unicode and special characters in values" do
      e1 = insert_event(%{name: "Café résumé naïve"})
      _e2 = insert_event(%{name: "Regular name"})

      ast = parse!("name:'Café résumé naïve'")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      assert rows == [e1]
    end

    test "case sensitivity in field names and values" do
      _e1 = insert_event(%{status: "Live"})
      e2 = insert_event(%{status: "live"})

      ast = parse!("status:live")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])
      rows = Repo.all(q)
      assert e2 in rows
    end
  end

  describe "metadata and query optimization" do
    test "meta.uses_full_text? flag set correctly" do
      _e1 = insert_event(%{name: "test"})

      ast1 = parse!("status:live")
      assert {:ok, _q1, meta1} = Builder.apply(Event, ast1, schema: Event, search_fields: [])
      assert meta1.uses_full_text? == false

      ast2 = parse!("searchterm")

      assert {:ok, _q2, meta2} =
               Builder.apply(Event, ast2,
                 schema: Event,
                 search_fields: ["name"],
                 search_strategy: :ilike
               )

      assert meta2.uses_full_text? == true

      ast3 = parse!("status:live AND searchterm")

      assert {:ok, _q3, meta3} =
               Builder.apply(Event, ast3,
                 schema: Event,
                 search_fields: ["name"],
                 search_strategy: :ilike
               )

      assert meta3.uses_full_text? == true
    end

    test "distinct applied when joining has_many associations" do
      tag1 = insert_tag(%{name: "music"})
      tag2 = insert_tag(%{name: "live"})

      e1 = insert_event(%{name: "Concert"})
      insert_event_tag(%{event_id: e1.id, tag_id: tag1.id})
      insert_event_tag(%{event_id: e1.id, tag_id: tag2.id})

      ast = parse!("tags.name:music")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event, search_fields: [])

      {sql, _params} = to_sql!(q)
      assert sql =~ "DISTINCT" or sql =~ "GROUP BY"
    end

    test "warnings metadata for unknown fields" do
      _e1 = insert_event(%{status: "live"})

      ast = parse!("status:live AND unknown_field:value")

      assert {:ok, _q, meta} =
               Builder.apply(Event, ast,
                 schema: Event,
                 search_fields: [],
                 unknown_field: :warn
               )

      assert is_list(meta.warnings)
      assert length(meta.warnings) > 0

      warning = Enum.find(meta.warnings, &(&1[:type] == :unknown_field))
      assert warning != nil
      assert warning[:path] == "unknown_field"
    end
  end

  describe "date-only for datetime fields" do
    test "equality with date string creates day boundary range for naive_datetime (inserted_at)" do
      date_str = "2025-08-07"
      target_date = ~D[2025-08-07]

      start_of_day = NaiveDateTime.new!(target_date, ~T[08:30:00])
      e1 = insert_event(%{name: "Target event", inserted_at: start_of_day})

      prev_day = NaiveDateTime.new!(Date.add(target_date, -1), ~T[23:59:59])
      _e2 = insert_event(%{name: "Previous day", inserted_at: prev_day})

      next_day = NaiveDateTime.new!(Date.add(target_date, 1), ~T[00:00:01])
      _e3 = insert_event(%{name: "Next day", inserted_at: next_day})

      ast = parse!("inserted_at:#{date_str}")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event)

      rows = Repo.all(q)
      assert length(rows) == 1
      assert hd(rows).id == e1.id
      assert hd(rows).name == "Target event"
    end

    test "equality with date string creates day boundary range for utc_datetime (time_start)" do
      date_str = "2025-08-07"
      target_date = ~D[2025-08-07]

      start_of_day = DateTime.new!(target_date, ~T[14:30:00], "Etc/UTC")
      e1 = insert_event(%{name: "Target event", time_start: start_of_day})

      prev_day = DateTime.new!(Date.add(target_date, -1), ~T[23:59:59], "Etc/UTC")
      _e2 = insert_event(%{name: "Previous day", time_start: prev_day})

      next_day = DateTime.new!(Date.add(target_date, 1), ~T[00:00:01], "Etc/UTC")
      _e3 = insert_event(%{name: "Next day", time_start: next_day})

      ast = parse!("time_start:#{date_str}")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event)

      rows = Repo.all(q)
      assert length(rows) == 1
      assert hd(rows).id == e1.id
      assert hd(rows).name == "Target event"
    end

    test "greater than or equal with date string for naive_datetime" do
      date_str = "2025-08-07"
      target_date = ~D[2025-08-07]

      before_date = NaiveDateTime.new!(Date.add(target_date, -1), ~T[23:59:59])
      _e1 = insert_event(%{name: "Before", inserted_at: before_date})

      on_date = NaiveDateTime.new!(target_date, ~T[08:30:00])
      e2 = insert_event(%{name: "On date", inserted_at: on_date})

      after_date = NaiveDateTime.new!(Date.add(target_date, 1), ~T[01:00:00])
      e3 = insert_event(%{name: "After", inserted_at: after_date})

      ast = parse!("inserted_at>=#{date_str}")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event)

      rows = Repo.all(q)
      assert length(rows) == 2
      row_names = Enum.map(rows, & &1.name) |> Enum.sort()
      assert row_names == ["After", "On date"]
      row_ids = Enum.map(rows, & &1.id) |> Enum.sort()
      assert row_ids == Enum.sort([e2.id, e3.id])
    end

    test "greater than or equal with date string for utc_datetime" do
      date_str = "2025-08-07"
      target_date = ~D[2025-08-07]

      before_date = DateTime.new!(Date.add(target_date, -1), ~T[23:59:59], "Etc/UTC")
      _e1 = insert_event(%{name: "Before UTC", time_start: before_date})

      on_date = DateTime.new!(target_date, ~T[08:30:00], "Etc/UTC")
      e2 = insert_event(%{name: "On date UTC", time_start: on_date})

      after_date = DateTime.new!(Date.add(target_date, 1), ~T[01:00:00], "Etc/UTC")
      e3 = insert_event(%{name: "After UTC", time_start: after_date})

      ast = parse!("time_start>=#{date_str}")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event)

      rows = Repo.all(q)
      assert length(rows) == 2
      row_names = Enum.map(rows, & &1.name) |> Enum.sort()
      assert row_names == ["After UTC", "On date UTC"]
      row_ids = Enum.map(rows, & &1.id) |> Enum.sort()
      assert row_ids == Enum.sort([e2.id, e3.id])
    end

    test "less than with date string for naive_datetime" do
      date_str = "2025-08-07"
      target_date = ~D[2025-08-07]

      before_date = NaiveDateTime.new!(Date.add(target_date, -1), ~T[23:59:59])
      e1 = insert_event(%{name: "Before", inserted_at: before_date})

      on_date = NaiveDateTime.new!(target_date, ~T[08:30:00])
      _e2 = insert_event(%{name: "On date", inserted_at: on_date})

      ast = parse!("inserted_at<#{date_str}")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event)

      rows = Repo.all(q)
      assert length(rows) == 1
      assert hd(rows).id == e1.id
      assert hd(rows).name == "Before"
    end

    test "less than with date string for utc_datetime" do
      date_str = "2025-08-07"
      target_date = ~D[2025-08-07]

      before_date = DateTime.new!(Date.add(target_date, -1), ~T[23:59:59], "Etc/UTC")
      e1 = insert_event(%{name: "Before UTC", time_start: before_date})

      on_date = DateTime.new!(target_date, ~T[08:30:00], "Etc/UTC")
      _e2 = insert_event(%{name: "On date UTC", time_start: on_date})

      ast = parse!("time_start<#{date_str}")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event)

      rows = Repo.all(q)
      assert length(rows) == 1
      assert hd(rows).id == e1.id
      assert hd(rows).name == "Before UTC"
    end

    test "invalid date string still returns error" do
      ast = parse!("inserted_at:invalid-date")

      assert {:error, {:builder, :invalid_value}} = Builder.apply(Event, ast, schema: Event)
    end

    test "regular naive datetime strings still work" do
      datetime_str = "2025-08-07T10:30:00"
      target_datetime = ~N[2025-08-07 10:30:00]

      e1 = insert_event(%{name: "Exact naive match", inserted_at: target_datetime})
      _e2 = insert_event(%{name: "Different naive time", inserted_at: ~N[2025-08-07 11:00:00]})

      ast = parse!("inserted_at:\"#{datetime_str}\"")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event)

      rows = Repo.all(q)
      assert length(rows) == 1
      assert hd(rows).id == e1.id
      assert hd(rows).name == "Exact naive match"
    end

    test "regular utc datetime strings still work" do
      datetime_str = "2025-08-07T10:30:00Z"
      target_datetime = ~U[2025-08-07 10:30:00Z]

      e1 = insert_event(%{name: "Exact UTC match", time_start: target_datetime})
      _e2 = insert_event(%{name: "Different UTC time", time_start: ~U[2025-08-07 11:00:00Z]})

      ast = parse!("time_start:\"#{datetime_str}\"")

      assert {:ok, q, _meta} = Builder.apply(Event, ast, schema: Event)

      rows = Repo.all(q)
      assert length(rows) == 1
      assert hd(rows).id == e1.id
      assert hd(rows).name == "Exact UTC match"
    end
  end
end
