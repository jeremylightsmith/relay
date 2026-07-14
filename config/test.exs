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
# tests don't care. Running the server always is harmless for the fast suite.
config :relay, RelayWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "d7ZQNZUWtP3mPcEZbpa3EzYQ70t1YmaHBlp+2uxkBeAXR5d6FfGSGzr/toxbUS5k",
  server: true

# Native-auth Google token validator: static dummy client id + a Req.Test plug
# so GoogleTokenValidator hits an in-process stub instead of real Google.
config :relay, :google_client_id, "test-google-client-id"
config :relay, :google_tokeninfo_req_options, plug: {Req.Test, Relay.Accounts.GoogleTokenValidator}

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
