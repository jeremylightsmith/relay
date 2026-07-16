# Exclude browser (Playwright) tests by default so `mix test` / `mix precommit`
# stay fast and never need a browser. CI runs them explicitly via
# `mix test --only playwright`.
ExUnit.start(exclude: [:playwright])

# Only spin up the Playwright driver when :playwright tests are actually
# included (i.e. `mix test --only playwright`). The fast CI job does not install
# Playwright, so the driver must NOT start there.
if :playwright in Keyword.get(ExUnit.configuration(), :include, []) do
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
  # The endpoint binds an OS-assigned ephemeral port (port: 0 in
  # config/test.exs), so read back the *actually bound* port.
  # Endpoint.url() must not be used — it reports the configured port (0).
  # The 127.0.0.1 literal matches the bind IP exactly, avoiding any
  # localhost -> ::1 resolution ambiguity.
  {:ok, {_ip, port}} = RelayWeb.Endpoint.server_info(:http)
  Application.put_env(:phoenix_test, :base_url, "http://127.0.0.1:#{port}")
end

Ecto.Adapters.SQL.Sandbox.mode(Relay.Repo, :manual)
