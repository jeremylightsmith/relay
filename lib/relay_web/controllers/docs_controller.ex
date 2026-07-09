defmodule RelayWeb.DocsController do
  @moduledoc """
  Serves the public docs pages: a setup / getting-started guide at `/docs` and the
  hand-written REST API reference at `/docs/api`.

  Each page's markdown source lives under `priv/docs/` and is embedded at compile time via
  `@external_resource` so it ships in releases and recompiles on change in dev, then rendered
  through the shared (sanitized) `Relay.Markdown` context.
  """
  use RelayWeb, :controller

  @api_md_path Application.app_dir(:relay, "priv/docs/api.md")
  @external_resource @api_md_path
  @api_markdown File.read!(@api_md_path)

  @setup_md_path Application.app_dir(:relay, "priv/docs/setup.md")
  @external_resource @setup_md_path
  @setup_markdown File.read!(@setup_md_path)

  def index(conn, _params) do
    render(conn, :index,
      setup_html: Relay.Markdown.to_html(@setup_markdown),
      page_title: "API & Setup"
    )
  end

  def api(conn, _params) do
    render(conn, :api,
      api_html: Relay.Markdown.to_html(@api_markdown),
      page_title: "API Reference"
    )
  end
end
