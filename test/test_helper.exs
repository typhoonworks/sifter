Application.ensure_all_started(:postgrex)
{:ok, _} = Sifter.Test.Repo.start_link()

# Run migrations before starting tests
Code.require_file("test/support/migrations.exs")

case Ecto.Migrator.up(Sifter.Test.Repo, 0, Sifter.Test.Migrations, log: false) do
  :ok -> :ok
  :already_up -> :ok
  {:error, :already_up} -> :ok
end

ExUnit.start(assert_receive_timeout: 500, refute_receive_timeout: 50)
Ecto.Adapters.SQL.Sandbox.mode(Sifter.Test.Repo, :manual)
