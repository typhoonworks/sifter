import Config

config :logger, level: :warning

config :sifter,
  ecto_repo: Sifter.Test.Repo

config :sifter, Sifter.Test.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 2345,
  database: "sifter_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  priv: "test/support",
  show_sensitive_data_on_connection_error: true,
  stacktrace: true

config :sifter, ecto_repos: [Sifter.Test.Repo]
