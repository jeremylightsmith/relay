defmodule HamacaWeb.BoardBarComponents do
  @moduledoc """
  The board pages' one-row top bar (RE497): **logo · board name ▾ · [view switch, `sm`+] · … ·
  ⋯ · avatar**. Designed by the card mockups "B — one row: board name opens the switcher, ⋯ holds
  views" (phones) and "Wide B — the phone's ⋯ on desktop too" (`sm` and up).

  These are the bar's pieces; `Layouts.app/1` with `board_bar={true}` lays them out:

    * `board_bar_title/1` — the `<:title>`: the board switcher (`HamacaWeb.BoardSwitcherComponent`)
      and, from `sm` up, the view switch (`CoreComponents.board_view_tabs/1`).
    * `board_switcher_menu/1` — the switcher's pure render (button + menu), shared by the
      LiveComponent and its story.
    * `board_more_menu/1` — the ⋯ menu: the View section on phones, then Agent log (wide only),
      Board settings and Setup.

  Both menus open and close client-side (`JS.toggle` / `JS.hide`), so an open costs no server
  round-trip — except the switcher's first open, which also pushes `"load"` to fetch the board
  summaries. Each `phx-click-away` sits on the menu's **wrapper**, not on the `<ul>`: on the
  menu it would hide the menu in the same tick the button's click toggled it open. Escape is a
  client-only `phx-window-keydown` `JS.hide`, so it never contends with `BoardLive`'s window
  Escape handler (`close_drawer`). The `open` attrs exist only so the storybook can show a menu
  open; the app never re-renders a menu open from the server (JS command state is sticky
  across patches, which is what keeps the switcher open while `"load"` patches its rows in).
  """
  use HamacaWeb, :html

  alias HamacaWeb.SetupComponents

  @views HamacaWeb.CoreComponents.board_view_names()

  @doc """
  The board bar's `<:title>`: the board switcher, then the view switch from `sm` up. The
  switch is wrapped rather than given a `hidden` class because `board_view_tabs/1` sets
  `display:flex` inline, which a class can't override.
  """
  attr :board, :map, required: true, doc: "needs `slug` and `name`"
  attr :user, :map, required: true, doc: "the `%Schemas.User{}` whose boards the switcher lists"
  attr :active_view, :atom, values: @views, required: true

  def board_bar_title(assigns) do
    ~H"""
    <.live_component
      module={HamacaWeb.BoardSwitcherComponent}
      id="board-switcher"
      board={@board}
      user={@user}
    />
    <div class="hidden sm:flex">
      <.board_view_tabs board_slug={@board.slug} active={@active_view} />
    </div>
    """
  end

  @doc """
  The board switcher: the board name ▾ button and its menu — All boards, then one row per
  board (`Hamaca.Cards.list_board_summaries/1` rows) with its star, key, AI-working dot and
  needs-you badge, the current board checked. `boards: nil` means not loaded yet, so only All
  boards renders.
  """
  attr :board, :map, required: true, doc: "the current board; needs `slug` and `name`"
  attr :boards, :list, default: nil, doc: "board summary rows; nil until loaded"
  attr :open, :boolean, default: false, doc: "storybook only — render the menu open"
  attr :target, :any, default: nil, doc: "the LiveComponent's `@myself`, which handles \"load\""

  def board_switcher_menu(assigns) do
    ~H"""
    <div
      id="board-switcher"
      class="relative flex min-w-0 flex-1 sm:flex-initial"
      phx-click-away={JS.hide(to: "#board-switcher-menu")}
    >
      <button
        type="button"
        id="board-switcher-button"
        aria-label="Switch board"
        aria-haspopup="menu"
        class="flex min-h-[44px] min-w-0 flex-1 items-center gap-1 rounded-lg px-1.5 text-left hover:bg-base-200 sm:flex-initial sm:px-2"
        phx-click={JS.toggle(to: "#board-switcher-menu") |> JS.push("load", target: @target)}
      >
        <span id="board-name" class="truncate text-[15px] font-semibold">{@board.name}</span>
        <.icon name="hero-chevron-down" class="size-4 flex-none text-base-content/50" />
      </button>
      <ul
        id="board-switcher-menu"
        role="menu"
        class={[
          !@open && "hidden",
          "menu absolute left-0 top-full z-50 mt-1 w-72 max-w-[calc(100vw-2rem)] rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
        ]}
        phx-window-keydown={JS.hide(to: "#board-switcher-menu")}
        phx-key="Escape"
      >
        <li>
          <.link
            navigate={~p"/boards"}
            id="board-switcher-all-boards"
            class="min-h-[44px] text-base-content/80"
          >
            <.icon name="hero-arrow-left" class="size-4" /> All boards
          </.link>
        </li>
        <li class="divider my-1 h-px" aria-hidden="true"></li>
        <li :if={@boards} class="menu-title px-2 text-[10px] uppercase tracking-wider">
          Switch board
        </li>
        <li :for={row <- @boards || []}>
          <.link
            navigate={~p"/board/#{row.slug}"}
            id={"board-switcher-row-#{row.slug}"}
            aria-current={row.slug == @board.slug && "page"}
            class={[
              "flex min-h-[44px] items-center gap-2",
              row.slug == @board.slug && "font-semibold"
            ]}
          >
            <.icon
              :if={row.starred?}
              name="hero-star-solid"
              class="size-3.5 flex-none text-warning"
            />
            <span :if={!row.starred?} class="size-3.5 flex-none"></span>
            <span class="w-6 font-mono text-[11px] text-base-content/50">{row.key}</span>
            <span class="flex-1 truncate">{row.name}</span>
            <span
              :if={row.ai_active?}
              class="size-2 flex-none rounded-full bg-secondary"
              title="AI working"
            >
            </span>
            <span :if={row.needs_you_count > 0} class="badge badge-sm badge-primary">
              {row.needs_you_count}
            </span>
            <.icon
              :if={row.slug == @board.slug}
              name="hero-check"
              class="size-4 flex-none text-base-content/70"
            />
            <span :if={row.slug != @board.slug} class="size-4 flex-none"></span>
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  The board bar's ⋯ menu. Phones (below `sm`) get the View section — one entry per
  `CoreComponents.board_views/1` view — since the view switch leaves the bar there. Then
  Agent log (wide only, when `show_logs`), Board settings (when `settings_path`) and Setup
  (when `setup`, which also puts a primary dot on the ⋯ button). Breakpoints are CSS-only: the
  menu renders once.
  """
  attr :board_slug, :string, required: true
  attr :active_view, :atom, values: @views, required: true
  attr :show_logs, :boolean, default: false, doc: "offer the Agent log toggle (wide only)"
  attr :logs_open, :boolean, default: false
  attr :settings_path, :string, default: nil, doc: "nil hides Board settings"

  attr :setup, :map,
    default: nil,
    doc: "the `Hamaca.Setup.checklist/1` map; nil hides the Setup item and the dot"

  attr :open, :boolean, default: false, doc: "storybook only — render the menu open"

  def board_more_menu(assigns) do
    assigns = assign(assigns, :views, board_views(assigns.board_slug))

    ~H"""
    <div id="board-more" class="relative flex-none" phx-click-away={JS.hide(to: "#board-more-menu")}>
      <button
        type="button"
        id="board-more-button"
        aria-label="Board menu"
        title="Board menu"
        aria-haspopup="menu"
        class="btn btn-ghost btn-sm relative min-h-[44px] min-w-[44px] flex-none px-0 text-base-content/70"
        phx-click={JS.toggle(to: "#board-more-menu")}
      >
        <.icon name="hero-ellipsis-horizontal" class="size-5" />
        <span
          :if={@setup}
          id="board-more-dot"
          class="absolute right-1.5 top-2 size-2 rounded-full bg-primary"
          aria-hidden="true"
        >
        </span>
      </button>
      <ul
        id="board-more-menu"
        role="menu"
        class={[
          !@open && "hidden",
          "menu absolute right-0 top-full z-50 mt-1 w-60 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
        ]}
        phx-window-keydown={JS.hide(to: "#board-more-menu")}
        phx-key="Escape"
      >
        <li class="menu-title px-2 text-[10px] uppercase tracking-wider sm:hidden">View</li>
        <li :for={view <- @views} class="sm:hidden">
          <.link
            navigate={view.path}
            id={"board-more-view-#{view.key}"}
            aria-current={@active_view == view.view && "page"}
            class={["min-h-[44px]", @active_view == view.view && "font-semibold"]}
          >
            <.icon name={view.icon} class="size-4" />
            <span class="flex-1">{view.label}</span>
            <.icon :if={@active_view == view.view} name="hero-check" class="size-4" />
          </.link>
        </li>
        <li class="divider my-1 h-px sm:hidden" aria-hidden="true"></li>
        <li :if={@show_logs} class="hidden sm:flex">
          <button
            type="button"
            id="board-more-agent-log"
            aria-pressed={to_string(@logs_open)}
            class="min-h-[44px]"
            phx-click={
              JS.push(if(@logs_open, do: "close_logs", else: "open_logs"))
              |> JS.hide(to: "#board-more-menu")
            }
          >
            <.icon name="hero-command-line" class="size-4" />
            <span class="flex-1">Agent log</span>
            <.icon :if={@logs_open} name="hero-check" class="size-4" />
          </button>
        </li>
        <li :if={@settings_path}>
          <.link navigate={@settings_path} id="board-more-settings" class="min-h-[44px]">
            <.icon name="hero-cog-6-tooth" class="size-4" />
            <span class="flex-1">Board settings</span>
          </.link>
        </li>
        <li :if={@setup}>
          <button
            type="button"
            id="board-more-setup"
            class="min-h-[44px]"
            phx-click={JS.push("setup_open") |> JS.hide(to: "#board-more-menu")}
          >
            <.icon name="hero-rocket-launch" class="size-4" />
            <span class="flex-1">Setup</span>
            <SetupComponents.setup_chip id="board-more-setup-chip" checklist={@setup} />
          </button>
        </li>
      </ul>
    </div>
    """
  end
end
