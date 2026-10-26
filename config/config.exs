# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  hamaca: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  storybook: [
    args:
      ~w(js/storybook.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  # Docs-only bundle (mermaid). Kept out of the `hamaca` bundle so board pages never fetch it.
  # Two entries, neither bundled: docs.js has no imports of its own, and vendor/mermaid.min.js
  # must run as its own top-level classic script (not required into another module) for its
  # `globalThis["mermaid"] = ...` assignment to land — see the comment in assets/js/docs.js.
  # `--entry-names=[name]` flattens both outputs to the outdir root (no `js/`/`vendor/` nesting).
  docs: [
    args: ~w(js/docs.js vendor/mermaid.min.js --target=es2022 --outdir=../priv/static/assets/js --entry-names=[name]),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# ex_aws (S3 SigV4 signing for the prod attachment adapter) makes its HTTP
# calls through Req instead of pulling in hackney, so the app keeps a
# single HTTP client.
config :ex_aws, http_client: ExAws.Request.Req

# RLY-13: attachment byte storage. Dev/test use the hermetic filesystem
# adapter; prod overrides to S3 (Tigris) in config/runtime.exs.
config :hamaca, Hamaca.Attachments, storage: Hamaca.Attachments.Storage.Local

# Billing emails (RE464): `Hamaca.Mailer` (Swoosh). Off unless switched on — `:mail_enabled` is read
# through `Hamaca.Config.get/2`, and a disabled notifier only logs what it would have sent. Dev
# delivers to the Local adapter (browse it at /dev/mailbox), test to the Test adapter, and prod
# to Resend once config/runtime.exs sees RESEND_API_KEY + MAIL_FROM. `:app_url` is the absolute
# origin email links point at (the domain may not reach `HamacaWeb.Endpoint.url/0`). No hackney:
# only prod makes HTTP calls, through `Swoosh.ApiClient.Req` (config/prod.exs).
config :hamaca, Hamaca.Mailer, adapter: Swoosh.Adapters.Local

# Push (RLY-81). The Log adapter is the default so dev runs — and the whole
# trigger→recipient→dispatch pipeline is exercisable — without Apple credentials.
# config/runtime.exs swaps in the real APNS adapter in prod when creds are present.
config :hamaca, Hamaca.Push, adapter: Hamaca.Push.Delivery.Log, async: true

# Runs engine (ADR 0006 card 02 / RLY-132): runaway-protection knobs and the
# dispatch behaviour implementation ("give this node-job to a runner").
# NoopDispatcher = jobs sit :queued for the pull model (04's runners poll).
config :hamaca, Hamaca.Runs, breaker_threshold: 3, visit_cap: 20

# Configure the endpoint
config :hamaca, HamacaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HamacaWeb.ErrorHTML, json: HamacaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Hamaca.PubSub,
  live_view: [signing_salt: "c7EFJnnN"]

# Sign in with Apple (RE106): the identity-token `aud` allowlist — the iOS bundle id.
# This is the one definition of the default; config/runtime.exs overrides it only
# when APPLE_CLIENT_IDS is set (comma-separated).
config :hamaca, :apple_client_ids, ["com.jeremylightsmith.Relay"]
config :hamaca, :runs_dispatcher, Hamaca.Runs.NoopDispatcher

# Billing (RE460, ADR 0012): off unless switched on — a self-hosted install never bills.
# config/runtime.exs turns it on from BILLING_ENABLED (+ Stripe keys); tests turn it on with
# `Process.put(:billing_enabled, true)`. All are read through `Hamaca.Config.get/2`; the monthly
# price's default lives once, in `Hamaca.Billing.price_cents/0` (STRIPE_PRICE_CENTS overrides it).
config :hamaca,
  billing_enabled: false,
  billing_payments: Hamaca.Billing.Payments.Stripe

config :hamaca,
  ecto_repos: [Hamaca.Repo],
  generators: [timestamp_type: :utc_datetime]

# Other hostnames that serve this app (RE480); config/runtime.exs fills it from PHX_EXTRA_HOSTS.
# Their browser pages 301 to the canonical host (`HamacaWeb.Plugs.CanonicalHost`).
config :hamaca, extra_hosts: []

config :hamaca,
  mail_enabled: false,
  mail_from: "Hamaca <billing@localhost>",
  app_url: "http://localhost:4000"

# Server-side scheduler shell (ADR 0006 / RLY-133): off by default (no auto-start
# of a per-board scheduler) and bound to the real Hamaca.Runs adapter (RLY-136 / W11).
# NoopEngine stays in the tree — W8's scheduler tests still inject it directly.
config :hamaca, runs_auto_start: false, runs_engine: Hamaca.Runs.Scheduler.RunsEngine

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :swoosh, :api_client, false

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.1",
  hamaca: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),

    # Import environment specific config. This must remain at the bottom
    # of this file so it overrides the configuration defined above.
    cd: Path.expand("..", __DIR__)
  ],
  storybook: [
    args: ~w(
      --input=assets/css/storybook.css
      --output=priv/static/assets/css/storybook.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Google OAuth (Ueberauth). Only the provider list lives here; the client
# id/secret come from the environment at runtime (see config/runtime.exs)
# or static dummies in config/test.exs — never hardcode secrets.
config :ueberauth, Ueberauth,
  providers: [
    google: {Ueberauth.Strategy.Google, [default_scope: "email profile"]}
  ]

import_config "#{config_env()}.exs"
