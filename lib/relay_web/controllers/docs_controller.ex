defmodule RelayWeb.DocsController do
  @moduledoc """
  Serves the public documentation site. A compile-time page registry
  (`{slug, title, section, file}`) is the single source of truth for routing, the sidebar,
  active state, per-page `<title>`, and each page's TOC. Each markdown file under `priv/docs/`
  is embedded via `@external_resource` (ships in releases, recompiles on edit) and rendered
  through `Relay.Markdown.to_docs_html/1`.
  """
  use RelayWeb, :controller

  alias RelayWeb.DocsController.NotFoundError

  # {slug, title, section, filename}. Order defines sidebar order; the first entry is `/docs`.
  @pages_meta [
    {"introduction", "Introduction", "Get started", "introduction.md"},
    {"boards-and-stages", "Boards & stages", "Get started", "boards-and-stages.md"},
    {"cards-and-handoffs", "Cards & handoffs", "Get started", "cards-and-handoffs.md"},
    {"setup", "Setup", "Build with Relay", "setup.md"},
    {"cli", "CLI (bin/relay)", "Build with Relay", "cli.md"},
    {"agent-integration", "Agent integration", "Build with Relay", "agent-integration.md"},
    {"api", "REST API reference", "Build with Relay", "api.md"}
  ]

  @default_slug "introduction"

  for {_slug, _title, _section, file} <- @pages_meta do
    @external_resource Application.app_dir(:relay, "priv/docs/#{file}")
  end

  @pages (for {slug, title, section, file} <- @pages_meta do
            markdown = File.read!(Application.app_dir(:relay, "priv/docs/#{file}"))

            %{
              slug: slug,
              title: title,
              section: section,
              html: Relay.Markdown.to_docs_html(markdown),
              toc: Relay.Markdown.table_of_contents(markdown)
            }
          end)

  @sections @pages_meta |> Enum.map(&elem(&1, 2)) |> Enum.uniq()
  @sidebar Enum.map(@pages_meta, fn {slug, title, section, _file} ->
             %{slug: slug, title: title, section: section}
           end)

  def index(conn, _params), do: render_page(conn, @default_slug)

  def show(conn, %{"page" => slug}), do: render_page(conn, slug)

  defp render_page(conn, slug) do
    case Enum.find(@pages, &(&1.slug == slug)) do
      nil ->
        raise NotFoundError

      page ->
        render(conn, :show,
          page_html: page.html,
          toc: page.toc,
          sidebar: @sidebar,
          sections: @sections,
          active_slug: page.slug,
          page_title: page.title
        )
    end
  end
end
