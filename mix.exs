defmodule Relay.MixProject do
  use Mix.Project

  def project do
    [
      app: :relay,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:boundary, :phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Relay.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, "test.browser": :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.7"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons", tag: "v2.2.0", sparse: "optimized", app: false, compile: false, depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},

      # --- Markdown rendering for card long-form fields (RLY-3) ---
      {:mdex, "~> 0.13"},

      # --- Object storage for card attachments (RLY-13). ex_aws does S3 SigV4
      # request signing (what Req doesn't do); it's configured (see
      # config/config.exs) to make the actual HTTP calls through Req rather
      # than pulling in hackney, keeping one HTTP client in the app.
      # Prod-only — the test suite uses the Local filesystem adapter.
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:sweet_xml, "~> 0.7"},

      # --- Auth: Google OAuth via Ueberauth (MMF 01) ---
      {:ueberauth, "~> 0.10"},
      {:ueberauth_google, "~> 0.12"},

      # --- Architecture: enforced context/web boundaries (see lib/relay.ex) ---
      {:boundary, "~> 0.10"},

      # --- Push: ES256 JWS for the APNs provider token (RLY-81). A small
      # pure-Erlang crypto helper, not a push framework — we hand-roll the one
      # APNs call over Req/Finch rather than pull in pigeon/FCM. Approved at
      # RLY-81 Spec:Review.
      {:jose, "~> 1.11"},

      # --- Component workbench ---
      {:phoenix_storybook, "~> 1.1"},

      # --- Quality gate (wired into `mix precommit`) ---
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},

      # --- Testing: factories, high-level LiveView tests, browser journeys ---
      {:ex_machina, "~> 2.7", only: :test},
      {:phoenix_test, "~> 0.11", only: :test, runtime: false},
      {:phoenix_test_playwright, "~> 0.15", only: :test, runtime: false},

      # Deterministic async-test config/state propagation across process trees.
      {:process_tree, "~> 0.3"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test --warnings-as-errors"],
      # Browser journeys need a current JS/CSS bundle, so rebuild assets first —
      # otherwise the hooks under test run against a stale bundle.
      "test.browser": ["assets.build", "test --only playwright"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": [
        "compile",
        "tailwind relay",
        "tailwind storybook",
        "esbuild relay",
        "esbuild storybook",
        "esbuild docs"
      ],
      "assets.deploy": [
        "tailwind relay --minify",
        "tailwind storybook --minify",
        "esbuild relay --minify",
        "esbuild storybook --minify",
        "esbuild docs --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "sobelow --config",
        "deps.audit",
        "relay.gen_state --check",
        "relay.deps_graph --check",
        "test",
        "cmd python3 bin/test_relay.py"
      ]
    ]
  end
end
