[
  import_deps: [:ecto, :ecto_sql, :phoenix, :phoenix_storybook],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter, Styler],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs", "storybook/**/*.exs"]
]
