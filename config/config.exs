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
  relay: [
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
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :relay, Relay.Mailer, adapter: Swoosh.Adapters.Local

# Configure the endpoint
config :relay, RelayWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: RelayWeb.ErrorHTML, json: RelayWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Relay.PubSub,
  live_view: [signing_salt: "c7EFJnnN"]

config :relay,
  ecto_repos: [Relay.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.1",
  relay: [
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
