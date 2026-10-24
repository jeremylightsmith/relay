import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/relay start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :relay, RelayWeb.Endpoint, server: true
end

# The web server binds PORT (default 4003) in dev and prod. In :test the
# endpoint port stays as config/test.exs sets it (4002), so the suite can run
# alongside a running dev server (on 4003) without a port clash.
if config_env() != :test do
  config :relay, RelayWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4003"))]
end

# Billing emails (RE464): dev mail links point at the port the dev server actually binds. Prod
# overrides this with the public origin below.
if config_env() == :dev do
  config :relay, app_url: "http://localhost:#{System.get_env("PORT", "4003")}"
end

# Google OAuth credentials. Dev reads these from .envrc.local (direnv);
# prod from `fly secrets set`. Test uses static dummies from
# config/test.exs, which this must not override with nils.
if config_env() != :test do
  # "Suggest an idea" URL (RE397); unset/blank hides it. Read only via RelayWeb.Feedback.
  config :relay, feedback_url: System.get_env("RELAY_FEEDBACK_URL")

  config :relay,
    google_client_id: System.get_env("GOOGLE_CLIENT_ID"),
    google_ios_client_id: System.get_env("GOOGLE_IOS_CLIENT_ID")

  config :ueberauth, Ueberauth.Strategy.Google.OAuth,
    client_id: System.get_env("GOOGLE_CLIENT_ID"),
    client_secret: System.get_env("GOOGLE_CLIENT_SECRET")

  # Sign in with Apple audiences (RE106). The default lives in config/config.exs;
  # only an explicitly set APPLE_CLIENT_IDS (comma-separated) replaces it.
  if apple_client_ids = System.get_env("APPLE_CLIENT_IDS") do
    config :relay,
           :apple_client_ids,
           apple_client_ids |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end
end

# Billing (RE460, ADR 0012). BILLING_ENABLED=true turns it on only with both Stripe keys set,
# charging through Stripe at STRIPE_PRICE_CENTS (default: `Relay.Billing.price_cents/0`). Dev alone may switch it on with
# no Stripe keys, charging through the in-process Local adapter. Unset → off (self-host).
# Test configures billing in config/test.exs and turns it on per test; never here.
if config_env() != :test do
  blank? = fn value -> is_nil(value) or String.trim(value) == "" end
  stripe_secret_key = System.get_env("STRIPE_SECRET_KEY")
  stripe_webhook_secret = System.get_env("STRIPE_WEBHOOK_SECRET")

  cond do
    System.get_env("BILLING_ENABLED") != "true" ->
      :ok

    not blank?.(stripe_secret_key) and not blank?.(stripe_webhook_secret) ->
      # Only an explicit STRIPE_PRICE_CENTS is written; unset falls through to the one default
      # in `Relay.Billing.price_cents/0`.
      price_cents = System.get_env("STRIPE_PRICE_CENTS")

      config :relay,
        billing_enabled: true,
        billing_payments: Relay.Billing.Payments.Stripe,
        stripe_secret_key: stripe_secret_key,
        stripe_webhook_secret: stripe_webhook_secret

      if not blank?.(price_cents), do: config(:relay, billing_price_cents: String.to_integer(price_cents))

    config_env() == :dev ->
      config :relay, billing_enabled: true, billing_payments: Relay.Billing.Payments.Local

    true ->
      :ok
  end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  # Other hostnames that serve this same app (comma-separated), e.g. a second domain pointed at
  # it. They're only accepted as LiveView socket origins; every absolute URL the app generates
  # (install scripts, mail links, the runner's board URL) still uses PHX_HOST.
  extra_hosts =
    "PHX_EXTRA_HOSTS" |> System.get_env("") |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  mail_blank? = fn value -> is_nil(value) or String.trim(value) == "" end
  resend_api_key = System.get_env("RESEND_API_KEY")
  mail_from = System.get_env("MAIL_FROM")

  # Billing emails (RE464). Links in mail point at the public origin. Mail is sent through Resend
  # only when both RESEND_API_KEY and MAIL_FROM are set; otherwise it stays disabled and
  # `Relay.Billing.Notifier` just logs what it would have sent.
  config :relay, app_url: "https://#{host}"

  if not mail_blank?.(resend_api_key) and not mail_blank?.(mail_from) do
    config :relay, Relay.Mailer, adapter: Swoosh.Adapters.Resend, api_key: resend_api_key
    config :relay, mail_enabled: true, mail_from: mail_from
  end

  tigris_endpoint =
    URI.parse(System.get_env("AWS_ENDPOINT_URL_S3") || "https://fly.storage.tigris.dev")

  # Push (RLY-81). Only switch to the real APNs adapter when the credentials are
  # actually present — a prod boot without them keeps the Log adapter rather than
  # crashing the release. Secrets come from `fly secrets set`.
  apns_key = System.get_env("APNS_KEY_P8")
  apns_key_id = System.get_env("APNS_KEY_ID")
  apns_team_id = System.get_env("APNS_TEAM_ID")
  apns_topic = System.get_env("APNS_TOPIC")

  config :ex_aws, :s3,
    scheme: "#{tigris_endpoint.scheme}://",
    host: tigris_endpoint.host,
    region: "auto"

  config :ex_aws,
    access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
    secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
    region: "auto"

  if apns_key && apns_key_id && apns_team_id && apns_topic do
    config :relay, Relay.Push,
      adapter: Relay.Push.Delivery.APNS,
      async: true,
      apns: [
        key: apns_key,
        key_id: apns_key_id,
        team_id: apns_team_id,
        topic: apns_topic,
        env: System.get_env("APNS_ENV", "sandbox")
      ]
  else
    require Logger

    Logger.warning("[push] APNs credentials absent — falling back to the Log delivery adapter")
  end

  # RLY-13: attachments go to Tigris (S3-compatible) in prod. `fly storage create`
  # provisions the bucket and sets AWS_* / BUCKET_NAME / AWS_ENDPOINT_URL_S3.
  config :relay, Relay.Attachments, storage: Relay.Attachments.Storage.S3

  config :relay, Relay.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  config :relay, RelayWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: Enum.map([host | extra_hosts], &"//#{&1}"),
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :relay, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :relay, RelayWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :relay, RelayWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
