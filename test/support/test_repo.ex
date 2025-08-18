defmodule Sifter.Test.Repo do
  use Ecto.Repo,
    otp_app: :sifter,
    adapter: Ecto.Adapters.Postgres
end
