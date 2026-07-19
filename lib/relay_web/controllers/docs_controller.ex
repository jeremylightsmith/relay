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
  # Files under `architecture/` and `runbooks/` are read through the committed symlinks
  # `priv/docs/architecture -> ../../docs/architecture` and
  # `priv/docs/runbooks -> ../../docs/runbooks`, so `docs/architecture/` and `docs/runbooks/`
  # stay the single source of truth — there is no copy step and nothing to keep in sync.
  @pages_meta [
    {"getting-started", "Getting started", "Get started", "getting-started.md"},
    {"introduction", "Introduction", "Get started", "introduction.md"},
    {"boards-and-stages", "Boards & stages", "Get started", "boards-and-stages.md"},
    {"cards-and-handoffs", "Cards & handoffs", "Get started", "cards-and-handoffs.md"},
    {"statuses-and-outcomes", "Statuses & outcomes", "Get started", "statuses-and-outcomes.md"},
    {"cli", "CLI (bin/relay)", "Build with Relay", "cli.md"},
    {"agent-integration", "Agent integration", "Build with Relay", "agent-integration.md"},
    {"api", "REST API reference", "Build with Relay", "api.md"},
    {"authentication", "Authentication & API access", "Build with Relay", "authentication.md"},
    {"runbook-flow-cutover", "Enabling a flow safely", "Operations", "runbooks/flow-cutover.md"},
    {"architecture", "Overview", "Architecture", "architecture/README.md"},
    {"architecture-domain", "Domain", "Architecture", "architecture/domain.md"},
    {"architecture-runtime", "Runtime", "Architecture", "architecture/runtime.md"},
    {"architecture-runner", "Runner", "Architecture", "architecture/runner.md"},
    {"architecture-state", "State reference", "Architecture", "architecture/state.md"},
    {"architecture-deps", "Dependencies", "Architecture", "architecture/deps.md"}
  ]

  @default_slug "getting-started"

  for {_slug, _title, _section, file} <- @pages_meta do
    @external_resource Application.app_dir(:relay, "priv/docs/#{file}")
  end

  # Repo-relative path => slug, for the architecture pages only. This is what lets a link to
  # `domain.md` become `/docs/architecture-domain`; anything absent falls back to a GitHub URL.
  @slug_by_path (for {slug, _title, _section, file} <- @pages_meta,
                     String.starts_with?(file, "architecture/"),
                     into: %{} do
                   {"docs/#{file}", slug}
                 end)

  @pages (for {slug, title, section, file} <- @pages_meta do
            markdown = File.read!(Application.app_dir(:relay, "priv/docs/#{file}"))

            # Only the architecture pages carry repo-relative links; the hand-written
            # `priv/docs/*.md` pages already use site paths and are rendered exactly as before.
            opts =
              if String.starts_with?(file, "architecture/") do
                [rewrite_links: {Path.dirname("docs/#{file}"), @slug_by_path}]
              else
                []
              end

            %{
              slug: slug,
              title: title,
              section: section,
              html: Relay.Markdown.to_docs_html(markdown, opts),
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
          page_title: page.title,
          default_slug: @default_slug
        )
    end
  end
end
