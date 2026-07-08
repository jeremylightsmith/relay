# Exclude browser (Playwright) tests by default so `mix test` / `mix precommit`
# stay fast and never need a browser. CI runs them explicitly via
# `mix test --only playwright`.
ExUnit.start(exclude: [:playwright])

# Only spin up the Playwright driver when :playwright tests are actually
# included (i.e. `mix test --only playwright`). The fast CI job does not install
# Playwright, so the driver must NOT start there.
if :playwright in Keyword.get(ExUnit.configuration(), :include, []) do
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
  Application.put_env(:phoenix_test, :base_url, RelayWeb.Endpoint.url())
end

Ecto.Adapters.SQL.Sandbox.mode(Relay.Repo, :manual)
