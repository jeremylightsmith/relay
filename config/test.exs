import Config

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# PhoenixTest + Playwright driver. The fast suite excludes :playwright and never
# starts the driver (see test/test_helper.exs); CI runs it with --max-cases 1.
config :phoenix_test,
  otp_app: :relay,
  playwright: [
    browser: :chromium,
    # LiveView reconnect + first render on a cold CI runner can be slow.
    timeout: to_timeout(second: 10),
    # Give LiveView processes time to release the sandbox connection on test exit.
    ecto_sandbox_stop_owner_delay: 50
  ]

# In test we don't send emails
config :relay, Relay.Mailer, adapter: Swoosh.Adapters.Test

# Push (RLY-81): the Test adapter messages the caller, and `async: false` runs
# dispatch inline in the test process — so deliveries land in the test's mailbox
# and DB reads stay on the test's sandbox connection.
config :relay, Relay.Push, adapter: Relay.Push.Delivery.Test, async: false

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :relay, Relay.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "relay_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Browser (Playwright) tests need a real running server; the plain LiveView
# tests don't care. Port 0 makes the OS assign a free port per run, so
# concurrent test runs (runner worktrees, a human's ad-hoc `mix precommit`)
# never collide on :eaddrinuse. Playwright reads the actually-bound port
# back in test/test_helper.exs via RelayWeb.Endpoint.server_info(:http).
# `url: [host: ...]` must match the `127.0.0.1` bind IP (not the "localhost"
# from config/config.exs) or the LiveView socket's default check_origin
# rejects the browser's Origin header and every :playwright test 403s.
config :relay, RelayWeb.Endpoint,
  url: [host: "127.0.0.1"],
  http: [ip: {127, 0, 0, 1}, port: 0],
  secret_key_base: "d7ZQNZUWtP3mPcEZbpa3EzYQ70t1YmaHBlp+2uxkBeAXR5d6FfGSGzr/toxbUS5k",
  server: true

# APNs adapter tests inject a Req.Test plug (mirrors :google_tokeninfo_req_options),
# so no real Apple contact happens in the suite.
config :relay, :apns_req_options, plug: {Req.Test, Relay.Push.Delivery.APNS}

# Native-auth Google token validator: static dummy client id + a Req.Test plug
# so GoogleTokenValidator hits an in-process stub instead of real Google.
config :relay, :google_client_id, "test-google-client-id"
config :relay, :google_tokeninfo_req_options, plug: {Req.Test, Relay.Accounts.GoogleTokenValidator}

# Runs engine (RLY-132): tests start their own Relay.Runs.Supervisor via
# start_supervised!/1 — the app tree must not race them or touch the DB
# outside the test sandbox.
config :relay, :start_runs_supervisor, false

# Compile dev-only routes (GET /dev/login, LiveDashboard, storybook) into
# the test router so tests and the acceptance smoke can authenticate
# without real Google. Never enabled in prod.
config :relay, dev_routes: true

# Share the test's DB transaction with the browser session (see the SQL sandbox
# plug in RelayWeb.Endpoint, compiled only when this flag is set).
config :relay, sql_sandbox: true

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Dummy Google OAuth credentials — tests never contact real Google; the
# request-phase redirect is asserted but never followed.
config :ueberauth, Ueberauth.Strategy.Google.OAuth,
  client_id: "test-google-client-id",
  client_secret: "test-google-client-secret"
