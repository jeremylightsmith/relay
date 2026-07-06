defmodule Relay.Repo do
  use Boundary, deps: []

  use Ecto.Repo,
    otp_app: :relay,
    adapter: Ecto.Adapters.Postgres
end
