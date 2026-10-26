defmodule HamacaWeb.DocsController do
  @moduledoc """
  Serves the public documentation site. A compile-time page registry
  (`{slug, title, section, source}`) is the single source of truth for routing, the sidebar,
  active state, per-page `<title>`, and each page's TOC. A markdown source under `priv/docs/`
  is embedded via `@external_resource` (ships in releases, recompiles on edit) and rendered
  through `Hamaca.Markdown.to_docs_html/1`. A `{:heex, name}` source is a page template in
  `docs_html/pages/` that draws the board's own components; its TOC is read off its headings.
  """
  use HamacaWeb, :controller

  alias HamacaWeb.DocsController.NotFoundError

  # {slug, title, section, filename | {:heex, template}}. Order defines sidebar order; the first
  # entry is `/docs`.
  # Files under `architecture/` and `runbooks/` are read through the committed symlinks
  # `priv/docs/architecture -> ../../docs/architecture` and
  # `priv/docs/runbooks -> ../../docs/runbooks`, so `docs/architecture/` and `docs/runbooks/`
  # stay the single source of truth — there is no copy step and nothing to keep in sync.
  @pages_meta [
    {"getting-started", "Getting started", "Get started", "getting-started.md"},
    {"introduction", "Introduction", "Get started", "introduction.md"},
    {"how-hamaca-works", "How Hamaca works", "Get started", {:heex, :how_hamaca_works}},
    {"statuses-and-outcomes", "Statuses & outcomes", "Get started", "statuses-and-outcomes.md"},
    {"billing", "Billing & self-hosting", "Get started", "billing.md"},
    {"cli", "CLI (./hamaca)", "Build with Hamaca", "cli.md"},
    {"api", "REST API reference", "Build with Hamaca", "api.md"},
    {"authentication", "Authentication & API access", "Build with Hamaca", "authentication.md"},
    {"runbook-flow-cutover", "Enabling a flow safely", "Operations", "runbooks/flow-cutover.md"},
    {"architecture", "Overview", "Architecture", "architecture/README.md"},
    {"architecture-domain", "Domain", "Architecture", "architecture/domain.md"},
    {"architecture-runtime", "Runtime", "Architecture", "architecture/runtime.md"},
    {"architecture-runner", "Runner", "Architecture", "architecture/runner.md"},
    {"architecture-state", "State reference", "Architecture", "architecture/state.md"},
    {"architecture-failures", "Failure modes", "Architecture", "architecture/failures.md"},
    {"architecture-deps", "Dependencies", "Architecture", "architecture/deps.md"}
  ]

  @default_slug "getting-started"

  for {_slug, _title, _section, file} <- @pages_meta, is_binary(file) do
    @external_resource Application.app_dir(:hamaca, "priv/docs/#{file}")
  end

  # Repo-relative path => slug, for the architecture pages only. This is what lets a link to
  # `domain.md` become `/docs/architecture-domain`; anything absent falls back to a GitHub URL.
  @slug_by_path (for {slug, _title, _section, file} <- @pages_meta,
                     is_binary(file),
                     String.starts_with?(file, "architecture/"),
                     into: %{} do
                   {"docs/#{file}", slug}
                 end)

  @pages (for {slug, title, section, file} <- @pages_meta do
            case file do
              {:heex, template} ->
                %{slug: slug, title: title, section: section, heex: template}

              file ->
                markdown = File.read!(Application.app_dir(:hamaca, "priv/docs/#{file}"))

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
                  heex: nil,
                  html: Hamaca.Markdown.to_docs_html(markdown, opts),
                  toc: Hamaca.Markdown.table_of_contents(markdown)
                }
            end
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
        {html, toc} = page_body(page)

        render(conn, :show,
          page_html: html,
          toc: toc,
          sidebar: @sidebar,
          sections: @sections,
          active_slug: page.slug,
          page_title: page.title,
          default_slug: @default_slug
        )
    end
  end

  defp page_body(%{heex: nil, html: html, toc: toc}), do: {html, toc}

  defp page_body(%{heex: template}) do
    html =
      HamacaWeb.DocsHTML
      |> apply(template, [%{}])
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    {{:safe, html}, heex_toc(html)}
  end

  # The "On this page" entries for a HEEx page: its `<h2 id>` / `<h3 id>` headings, in order —
  # the same `%{level, text, anchor}` shape `Hamaca.Markdown.table_of_contents/1` returns.
  defp heex_toc(html) do
    for [_, level, anchor, inner] <- Regex.scan(~r{<h([23])[^>]*\sid="([^"]+)"[^>]*>(.*?)</h\1>}s, html) do
      %{level: String.to_integer(level), anchor: anchor, text: inner |> String.replace(~r/<[^>]+>/, "") |> String.trim()}
    end
  end
end
