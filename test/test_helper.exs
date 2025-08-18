Application.ensure_all_started(:postgrex)

Sifter.Test.Repo.start_link()
ExUnit.start(assert_receive_timeout: 500, refute_receive_timeout: 50)
Ecto.Adapters.SQL.Sandbox.mode(Sifter.Test.Repo, :manual)
