defmodule Sifter.OptionsTest do
  use ExUnit.Case, async: true

  alias Sifter.Options

  describe "mode/1" do
    test "lenient mode returns default values" do
      opts = Options.mode(:lenient)
      assert opts.unknown_field == :ignore
      assert opts.unknown_assoc == :ignore
      assert opts.unsupported_op == :error
      assert opts.invalid_cast == :error
      assert opts.max_joins == 1
      assert opts.join_overflow == :error
      assert opts.empty_in == false
    end

    test "strict mode returns strict values" do
      opts = Options.mode(:strict)
      assert opts.unknown_field == :error
      assert opts.unknown_assoc == :error
      assert opts.unsupported_op == :error
      assert opts.invalid_cast == :error
      assert opts.max_joins == 1
      assert opts.join_overflow == :error
      assert opts.empty_in == false
    end
  end

  describe "from_keyword/1" do
    test "creates options from keyword list" do
      opts =
        Options.from_keyword(
          unknown_field: :warn,
          max_joins: 5,
          empty_in: true
        )

      assert opts.unknown_field == :warn
      assert opts.max_joins == 5
      assert opts.empty_in == true
      assert opts.unknown_assoc == :ignore
    end

    test "creates options with partial keyword list" do
      opts = Options.from_keyword(unknown_field: :error)
      assert opts.unknown_field == :error
      assert opts.unknown_assoc == :ignore
      assert opts.unsupported_op == :error
    end

    test "creates options with empty keyword list" do
      opts = Options.from_keyword([])
      assert opts.unknown_field == :ignore
      assert opts.unknown_assoc == :ignore
      assert opts.unsupported_op == :error
    end
  end

  describe "merge/2" do
    test "merges keyword list into existing options" do
      base = Options.mode(:lenient)
      merged = Options.merge(base, unknown_field: :warn, max_joins: 3)

      assert merged.unknown_field == :warn
      assert merged.max_joins == 3
      assert merged.unknown_assoc == :ignore
    end

    test "overrides existing values" do
      base = Options.mode(:strict)
      merged = Options.merge(base, unknown_field: :ignore, invalid_cast: :warn)

      assert merged.unknown_field == :ignore
      assert merged.invalid_cast == :warn
      assert merged.unknown_assoc == :error
    end

    test "merges empty keyword list" do
      base = Options.mode(:strict)
      merged = Options.merge(base, [])

      assert merged == base
    end
  end

  describe "resolve/1" do
    setup do
      on_exit(fn ->
        Application.delete_env(:sifter, :options)
        Process.delete(:sifter_options)
      end)
    end

    test "defaults to lenient mode with no configuration" do
      opts = Options.resolve()
      assert opts.unknown_field == :ignore
      assert opts.unknown_assoc == :ignore
      assert opts.unsupported_op == :error
    end

    test "respects application config as :lenient" do
      Application.put_env(:sifter, :options, :lenient)
      opts = Options.resolve()
      assert opts.unknown_field == :ignore
      assert opts.unknown_assoc == :ignore
    end

    test "respects application config as :strict" do
      Application.put_env(:sifter, :options, :strict)
      opts = Options.resolve()
      assert opts.unknown_field == :error
      assert opts.unknown_assoc == :error
    end

    test "respects application config as keyword list" do
      Application.put_env(:sifter, :options, unknown_field: :warn, max_joins: 10)
      opts = Options.resolve()
      assert opts.unknown_field == :warn
      assert opts.max_joins == 10
    end

    test "respects application config as struct" do
      config_opts = %Options{unknown_field: :warn, max_joins: 5}
      Application.put_env(:sifter, :options, config_opts)
      opts = Options.resolve()
      assert opts.unknown_field == :warn
      assert opts.max_joins == 5
    end

    test "process config overrides application config" do
      Application.put_env(:sifter, :options, :strict)
      Process.put(:sifter_options, :lenient)
      opts = Options.resolve()
      assert opts.unknown_field == :ignore
      assert opts.unknown_assoc == :ignore
    end

    test "process config as keyword list merges with app config" do
      Application.put_env(:sifter, :options, unknown_field: :error, max_joins: 2)
      Process.put(:sifter_options, unknown_field: :warn, empty_in: true)
      opts = Options.resolve()
      assert opts.unknown_field == :warn
      assert opts.max_joins == 2
      assert opts.empty_in == true
    end

    test "process config as struct replaces app config" do
      Application.put_env(:sifter, :options, :strict)
      process_opts = %Options{unknown_field: :ignore}
      Process.put(:sifter_options, process_opts)
      opts = Options.resolve()
      assert opts.unknown_field == :ignore
      assert opts.unknown_assoc == :ignore
    end

    test "call options with :mode overrides all" do
      Application.put_env(:sifter, :options, :strict)
      Process.put(:sifter_options, unknown_field: :warn)
      opts = Options.resolve(mode: :lenient)
      assert opts.unknown_field == :ignore
      assert opts.unknown_assoc == :ignore
    end

    test "call options without :mode merges with existing" do
      Application.put_env(:sifter, :options, :lenient)
      opts = Options.resolve(unknown_field: :error, max_joins: 7)
      assert opts.unknown_field == :error
      assert opts.max_joins == 7
      assert opts.unknown_assoc == :ignore
    end

    test "call options merges specific fields after mode" do
      opts = Options.resolve(mode: :strict, max_joins: 20, empty_in: :error)
      assert opts.unknown_field == :error
      assert opts.max_joins == 20
      assert opts.empty_in == :error
    end

    test "precedence: call > process > application" do
      Application.put_env(:sifter, :options, unknown_field: :ignore, max_joins: 1)
      Process.put(:sifter_options, unknown_field: :warn, max_joins: 5)
      opts = Options.resolve(unknown_field: :error)

      assert opts.unknown_field == :error
      assert opts.max_joins == 5
    end

    test "ignores unknown keys in call options" do
      opts = Options.resolve(unknown_key: :value, max_joins: 3)
      assert opts.max_joins == 3
    end
  end

  describe "struct defaults" do
    test "has expected default values" do
      opts = %Options{}
      assert opts.unknown_field == :ignore
      assert opts.unknown_assoc == :ignore
      assert opts.unsupported_op == :error
      assert opts.invalid_cast == :error
      assert opts.max_joins == 1
      assert opts.join_overflow == :error
      assert opts.empty_in == false
    end
  end

  describe "type specification" do
    test "all fields have valid values" do
      opts = %Options{
        unknown_field: :warn,
        unknown_assoc: :error,
        unsupported_op: :warn,
        invalid_cast: :ignore,
        max_joins: 0,
        join_overflow: :ignore,
        empty_in: :error
      }

      assert is_atom(opts.unknown_field)
      assert is_atom(opts.unknown_assoc)
      assert is_atom(opts.unsupported_op)
      assert is_atom(opts.invalid_cast)
      assert is_integer(opts.max_joins) and opts.max_joins >= 0
      assert is_atom(opts.join_overflow)
      assert opts.empty_in in [false, true, :error]
    end
  end
end
