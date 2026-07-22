defmodule RelayWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use RelayWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :wide, :boolean,
    default: false,
    doc: "when true, use the full-width content container (board pages)"

  attr :crumb, :boolean,
    default: false,
    doc: "render the 'Boards' breadcrumb button + separator before the title"

  attr :embed, :boolean,
    default: false,
    doc: "when true, suppress the web top-bar chrome (surface hosted in the native shell)"

  slot :title, doc: "the bar's title node (editable board name, or a plain span)"
  slot :actions, doc: "the view's contextual right-side controls"
  slot :menu_items, doc: "view-specific entries at the top of the avatar dropdown"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header
      :if={!@embed}
      id="top-bar"
      class="flex items-center gap-3 border-b border-base-300 bg-base-100 px-4 sm:px-5"
      style="height:53px;"
    >
      <.link
        navigate={~p"/boards"}
        id="top-bar-logo"
        title="All boards"
        class="flex items-center gap-2"
      >
        <img src={~p"/images/logo_light_128.png"} width="23" alt="Relay" />
        <span class="hidden md:inline text-[15px] font-semibold tracking-[-0.02em]">Relay</span>
      </.link>
      <div
        :if={@crumb or @title != []}
        style="width:1px;height:18px;background:oklch(0.90 0.006 255);flex:0 0 auto;"
      >
      </div>
      <div :if={@crumb} id="top-bar-crumb" class="flex flex-none items-center gap-[7px]">
        <.link
          navigate={~p"/boards"}
          id="top-bar-crumb-boards"
          class="flex items-center gap-1.5 rounded-[7px] px-[7px] py-1 text-[13px] font-semibold"
          style="color:oklch(0.50 0.02 255);"
        >
          <.icon name="hero-squares-2x2" class="size-3.5" /> Boards
        </.link>
        <span class="text-[13px]" style="color:oklch(0.78 0.02 255);">/</span>
      </div>
      <div id="top-bar-title" class="flex min-w-0 items-center text-[13px] font-medium">
        {render_slot(@title)}
      </div>
      <span class="flex-1"></span>
      {render_slot(@actions)}
      <div :if={@current_scope} id="top-bar-account" class="dropdown dropdown-end flex-none">
        <div
          tabindex="0"
          role="button"
          id="user-avatar"
          title={@current_scope.user.email}
          class="flex min-h-[44px] min-w-[44px] items-center justify-center"
        >
          <.avatar
            size={28}
            tint={:role}
            src={@current_scope.user.avatar_url}
            name={@current_scope.user.name}
            email={@current_scope.user.email}
          />
        </div>
        <ul
          tabindex="0"
          id="account-menu"
          class="menu dropdown-content z-50 mt-2 w-60 rounded-box bg-base-100 p-2 shadow"
        >
          {render_slot(@menu_items)}
          <li class="menu-title px-2 text-[10px] uppercase tracking-wider">Theme</li>
          <li>
            <div class="pointer-events-auto px-1 py-1 hover:bg-transparent">
              <.theme_toggle />
            </div>
          </li>
          <li>
            <.link href={~p"/logout"} method="delete" id="sign-out">
              <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Sign out
            </.link>
          </li>
        </ul>
      </div>
    </header>

    <main class={[
      if(@wide, do: "px-0 py-0", else: "px-4 py-20 sm:px-6 lg:px-8")
    ]}>
      <div class={[if(@wide, do: "max-w-none", else: "mx-auto max-w-2xl space-y-4")]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The public roadmap shell (RLY-69, `/board/:slug/public`): board name, a "Public
  roadmap" label, the plain-text public URL, and a Sign in link (or the visitor's
  avatar when signed in) — no board-switcher nav, no `embed` handling, no
  `require_authenticated` assumptions. `current_scope` is nil for the majority
  signed-out visitor; here it only decides the sign-in-link-vs-avatar swap.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_scope, :map, default: nil
  attr :board_name, :string, required: true
  attr :public_path, :string, required: true, doc: "…/board/:slug/public, shown as plain text"
  slot :inner_block, required: true

  def public_board(assigns) do
    ~H"""
    <div class="min-h-screen" style="background:oklch(0.955 0.008 255);">
      <header
        id="public-board-header"
        class="flex items-center gap-3 border-b border-base-300 bg-base-100 px-4 sm:px-6"
        style="height:53px;"
      >
        <span class="truncate text-[15px] font-semibold">{@board_name}</span>
        <span class="badge badge-ghost badge-sm uppercase tracking-wider">Public roadmap</span>
        <span class="hidden truncate font-mono text-xs text-base-content/50 sm:inline">
          {@public_path}
        </span>
        <span class="flex-1"></span>
        <div :if={@current_scope} id="public-board-avatar">
          <.avatar
            size={28}
            tint={:role}
            src={@current_scope.user.avatar_url}
            name={@current_scope.user.name}
            email={@current_scope.user.email}
          />
        </div>
        <.link
          :if={!@current_scope}
          href={~p"/auth/google?return_to=#{@public_path}"}
          id="public-board-sign-in"
          class="btn btn-sm btn-primary"
        >
          Sign in
        </.link>
      </header>

      <main class="mx-auto max-w-6xl px-4 py-8 sm:px-6">
        {render_slot(@inner_block)}
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Public documentation layout: top nav (wordmark → `/`, "/ Docs" eyebrow, "Open the board"
  → `/board`), a left sidebar grouped by section with the active page highlighted, the article
  slot, and an "on this page" TOC rail. Public — never reads `current_scope`. Docs are static
  controller pages, so links use plain `href`. Loads the docs-only `docs.js` bundle (mermaid)
  — deliberately not in `app.js`, so board pages never fetch it.
  """
  attr :sidebar, :list, required: true, doc: "[%{slug, title, section}] in sidebar order"
  attr :sections, :list, required: true, doc: "ordered, de-duplicated section names"
  attr :active_slug, :string, required: true
  attr :default_slug, :string, required: true, doc: "the slug served at bare `/docs`"
  attr :toc, :list, default: [], doc: "[%{level, text, anchor}] for the current page"
  slot :inner_block, required: true

  def docs(assigns) do
    ~H"""
    <div class="docs-shell">
      <script defer phx-track-static type="text/javascript" src={~p"/assets/js/mermaid.min.js"}>
      </script>
      <script defer phx-track-static type="text/javascript" src={~p"/assets/js/docs.js"}>
      </script>
      <header class="docs-nav">
        <a href={~p"/"} class="docs-nav-brand">
          <img src={~p"/images/logo_light_128.png"} width="22" alt="Relay" />
          <span>Relay</span>
        </a>
        <span class="docs-nav-eyebrow">/ Docs</span>
        <a href={~p"/board"} class="docs-nav-cta">Open the board</a>
      </header>

      <div class="docs-body">
        <details class="docs-menu" open>
          <summary class="docs-menu-summary">
            <.icon name="hero-bars-3" class="size-4" /> Menu
          </summary>
          <nav class="docs-sidebar" aria-label="Documentation">
            <div :for={section <- @sections} class="docs-sidebar-section">
              <p class="docs-sidebar-heading">{section}</p>
              <ul>
                <li :for={page <- Enum.filter(@sidebar, &(&1.section == section))}>
                  <a
                    href={docs_link(page, @default_slug)}
                    class={["docs-sidebar-link", page.slug == @active_slug && "is-active"]}
                    aria-current={page.slug == @active_slug && "page"}
                  >
                    {page.title}
                  </a>
                </li>
              </ul>
            </div>
          </nav>
        </details>

        <main class="docs-main">
          <% current = docs_current(@sidebar, @active_slug) %>
          <nav class="docs-breadcrumb" aria-label="Breadcrumb">
            <a href={~p"/docs"}>Docs</a>
            <span class="docs-breadcrumb-sep">/</span>
            <span>{current.section}</span>
            <span class="docs-breadcrumb-sep">/</span>
            <span class="docs-breadcrumb-current">{current.title}</span>
          </nav>
          <p class="docs-eyebrow">{String.upcase(current.section)}</p>

          {render_slot(@inner_block)}

          <% prev = docs_adjacent(@sidebar, @active_slug, -1) %>
          <% next = docs_adjacent(@sidebar, @active_slug, 1) %>
          <nav :if={prev || next} class="docs-pager" aria-label="Page navigation">
            <a
              :if={prev}
              href={docs_link(prev, @default_slug)}
              class="docs-pager-link docs-pager-prev"
            >
              <span class="docs-pager-label">← Previous</span>
              <span class="docs-pager-title">{prev.title}</span>
            </a>
            <a
              :if={next}
              href={docs_link(next, @default_slug)}
              class="docs-pager-link docs-pager-next"
            >
              <span class="docs-pager-label">Next →</span>
              <span class="docs-pager-title">{next.title}</span>
            </a>
          </nav>
        </main>

        <nav :if={@toc != []} class="docs-toc" aria-label="On this page">
          <p class="docs-toc-heading">On this page</p>
          <ul>
            <li :for={item <- @toc} class={["docs-toc-item", "docs-toc-#{item.level}"]}>
              <a href={"##{item.anchor}"}>{item.text}</a>
            </li>
          </ul>
        </nav>
      </div>
    </div>
    """
  end

  # The landing page is reachable at bare `/docs`, so its sidebar and pager links point
  # there rather than at its own slug. Which page that is comes from the controller's
  # `@default_slug` — `@pages_meta` stays the single source.
  defp docs_link(%{slug: slug}, default_slug) when slug == default_slug, do: ~p"/docs"
  defp docs_link(%{slug: slug}, _default_slug), do: ~p"/docs/#{slug}"

  # The active page's own sidebar entry (title + section), for the breadcrumb and eyebrow
  # above the article.
  defp docs_current(sidebar, active_slug), do: Enum.find(sidebar, &(&1.slug == active_slug))

  # The page immediately before/after the active one in sidebar (reading) order, or nil
  # at either end. Powers the "prev / next" pager at the article foot.
  defp docs_adjacent(sidebar, active_slug, offset) do
    case Enum.find_index(sidebar, &(&1.slug == active_slug)) do
      nil -> nil
      index when index + offset < 0 -> nil
      index -> Enum.at(sidebar, index + offset)
    end
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:info}
        title={gettext("Relay is updating")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Standby — reconnecting…")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:info}
        title={gettext("Relay is updating")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Standby — reconnecting…")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
