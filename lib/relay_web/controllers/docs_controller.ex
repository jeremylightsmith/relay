defmodule RelayWeb.DocsController do
  @moduledoc """
  Serves the public, hand-written REST API reference at `/docs/api`.

  The markdown source (`priv/docs/api.md`) is embedded at compile time via
  `@external_resource` so it ships in releases and recompiles on change in dev,
  then rendered through the shared (sanitized) `Relay.Markdown` context.
  """
  use RelayWeb, :controller

  @api_md_path Application.app_dir(:relay, "priv/docs/api.md")
  @external_resource @api_md_path
  @api_markdown File.read!(@api_md_path)

  def api(conn, _params) do
    render(conn, :api,
      api_html: Relay.Markdown.to_html(@api_markdown),
      page_title: "API Reference"
    )
  end
end
