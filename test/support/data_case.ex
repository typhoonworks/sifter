defmodule Sifter.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Sifter.Test.Repo
      import Ecto.Query
      import Sifter.DataCase
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Sifter.Test.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Sifter.Test.Repo, {:shared, self()})
    end

    :ok
  end
end
