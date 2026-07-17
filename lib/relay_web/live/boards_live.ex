defmodule RelayWeb.BoardsLive do
  @moduledoc """
  The "Your boards" home (`/boards`): a grid of the user's active boards
  plus a "New board" tile — the switcher entry point (MMF 19). Each card
  navigates to `/board/<slug>`; the board you arrived from (`?from=<slug>`)
  gets a CURRENT badge. "New board" seeds a board and drops you into its
  settings to name it. Loads fresh on navigate (no realtime — out of scope).
  """

  use RelayWeb, :live_view

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Members

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide embed={@embed}>
      <:title>
        <span id="boards-title">Your boards</span>
      </:title>
      <:actions>
        <button
          type="button"
          id="top-bar-new-board"
          phx-click="new_board"
          class="btn btn-sm border-none font-semibold text-white"
          style="background:oklch(0.60 0.14 250);"
        >
          <span class="text-[15px] leading-none">+</span> New board
        </button>
      </:actions>
      <div id="boards-home" class="mx-auto max-w-[1120px] drawer:px-7 drawer:py-9">
        <%!-- RLY-95 · BOARDS-00 — phone-width title bar: 22px/600/-0.03em "Boards" on
              white over a hairline border (Relay Mobile.dc.html lines ~371–393). The
              mockup's search icon is deliberately skipped (Later polish). --%>
        <div
          id="boards-title-mobile"
          class="border-b bg-base-100 px-[18px] pb-3 pt-[6px] drawer:hidden"
          style="border-color:oklch(0.93 0.006 255);"
        >
          <span
            class="text-[22px] font-semibold"
            style="letter-spacing:-0.03em;color:oklch(0.22 0.02 255);"
          >
            Boards
          </span>
        </div>

        <div id="boards-desktop-header" class="hidden items-start justify-between gap-5 drawer:flex">
          <h1 class="m-0 text-[27px] font-semibold tracking-tight" style="color:oklch(0.24 0.02 255);">
            Your boards
          </h1>
          <div
            class="flex items-center gap-4 pt-2 font-mono text-[11px]"
            style="color:oklch(0.55 0.02 255);"
          >
            <span class="flex items-center gap-1.5">
              <span style="width:8px;height:8px;border-radius:2px;background:var(--color-secondary);"></span>AI
            </span>
            <span class="flex items-center gap-1.5">
              <span style="width:8px;height:8px;border-radius:2px;background:var(--color-primary);"></span>HUMAN
            </span>
          </div>
        </div>
        <p
          class="mb-7 mt-1 hidden max-w-[560px] text-sm leading-relaxed drawer:block"
          style="color:oklch(0.50 0.02 255);"
        >
          Each board is a shared workspace where you and Relay AI pass work between each other.
        </p>

        <div
          class="flex flex-col gap-2.5 p-3 drawer:grid drawer:gap-4 drawer:p-0"
          style="grid-template-columns:repeat(auto-fill,minmax(324px,1fr));"
        >
          <.link
            :for={b <- @boards}
            id={"board-card-#{b.slug}"}
            navigate={~p"/board/#{b.slug}"}
            class="flex flex-col overflow-hidden rounded-[12px] border border-[oklch(0.92_0.006_255)] bg-base-100 no-underline transition hover:-translate-y-0.5 drawer:rounded-[14px] drawer:border-[oklch(0.90_0.006_255)]"
          >
            <div class="hidden drawer:block" style={"height:3px;background:#{accent(b.slug)};"}></div>
            <div class="flex flex-col gap-2 p-3 drawer:gap-2.5 drawer:p-4">
              <div class="flex items-center gap-2 drawer:gap-2.5">
                <span
                  class="flex size-[18px] flex-none items-center justify-center rounded-[6px] drawer:size-[22px] drawer:rounded-[7px]"
                  style={"background:#{accent(b.slug)};"}
                >
                  <span class="hidden size-[7px] rounded-full bg-white drawer:block"></span>
                </span>
                <span
                  class="text-[14px] font-semibold tracking-[-0.015em] drawer:text-[15.5px] drawer:tracking-tight"
                  style="color:oklch(0.26 0.02 255);"
                >
                  {b.name}
                </span>
                <span class="flex-1"></span>
                <span
                  :if={b.slug == @from}
                  id={"board-card-#{b.slug}-current"}
                  class="rounded-[5px] px-1.5 py-0.5 font-mono text-[10px] font-semibold tracking-wide"
                  style="background:oklch(0.95 0.03 250);color:oklch(0.46 0.12 250);"
                >
                  CURRENT
                </span>
                <%!-- BOARDS-00 amber badge — phone width only. Two-type count when
                      embedded so it always agrees with the Needs-you tab (ADR 0005);
                      the web three-type sum otherwise. Keys off embed, not width. --%>
                <span
                  :if={badge_count(b, @embed) > 0}
                  id={"board-needs-you-mobile-#{b.slug}"}
                  class="rounded-[5px] border px-1.5 py-0.5 font-mono text-[8.5px] font-semibold drawer:hidden"
                  style="color:oklch(0.52 0.11 65);background:oklch(0.97 0.03 75);border-color:oklch(0.87 0.07 75);"
                >
                  {badge_count(b, @embed)} NEEDS YOU
                </span>
              </div>
              <span
                id={"board-meta-mobile-#{b.slug}"}
                class="font-mono text-[10.5px] drawer:hidden"
                style="color:oklch(0.58 0.02 255);"
              >
                {mobile_meta_label(b)}
              </span>
              <span
                class="hidden items-center gap-2 font-mono text-[11.5px] drawer:flex"
                style="color:oklch(0.58 0.02 255);"
              >
                {meta_label(b)}
                <span
                  :if={badge_count(b, @embed) > 0}
                  id={"board-needs-you-#{b.slug}"}
                  class="badge badge-warning badge-sm font-medium"
                >
                  {badge_count(b, @embed)} need you
                </span>
              </span>
              <div
                id={"board-card-foot-#{b.slug}"}
                class="mt-[3px] hidden items-center justify-between drawer:flex"
              >
                <.member_stack id={"board-members-#{b.slug}"} members={b.members} />
                <span class="font-mono text-[10.5px]" style="color:oklch(0.62 0.02 255);">
                  Updated {updated_label(b.updated_at)}
                </span>
              </div>
            </div>
          </.link>

          <button
            id="new-board-button"
            type="button"
            phx-click="new_board"
            class="hidden min-h-[220px] flex-col items-center justify-center gap-2.5 rounded-[14px] border border-dashed bg-transparent drawer:flex"
            style="border-color:oklch(0.86 0.01 255);color:oklch(0.55 0.02 255);"
          >
            <span class="flex size-[34px] items-center justify-center rounded-[9px] border-[1.5px] text-xl leading-none">
              +
            </span>
            <span class="text-[13px] font-semibold">New board</span>
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    boards = load_boards(socket.assigns.current_scope.user)

    {:ok,
     socket
     |> assign(:page_title, "Your boards")
     |> assign(:boards, boards)
     |> assign(:from, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :from, params["from"])}
  end

  @impl true
  def handle_event("new_board", _params, socket) do
    {:ok, board} =
      Boards.create_board(socket.assigns.current_scope.user, %{name: "Untitled board"})

    {:noreply, push_navigate(socket, to: ~p"/board/#{board.slug}/settings")}
  end

  defp load_boards(user) do
    for board <- Boards.list_boards(user) do
      rollup = Cards.needs_you_rollup(board)
      cards = Cards.list_cards(board)
      stages = Boards.list_stages(board)

      %{
        slug: board.slug,
        name: board.name,
        updated_at: board.updated_at,
        card_count: length(cards),
        stage_count: Enum.count(stages, &is_nil(&1.parent_id)),
        ai_active?: Enum.any?(cards, &(&1.status == :working and Cards.active_owner_type(&1) == :ai)),
        needs_you_count: rollup.needs_input + rollup.in_review + rollup.awaiting_human + rollup.agent_stalled,
        needs_you_two_type: rollup.needs_input + rollup.in_review + rollup.agent_stalled,
        members: Members.list_members(board)
      }
    end
  end

  # Which needs-you flavor the badge shows (decision 5 / ADR 0005): embedded, the
  # two-type count that matches the Needs-you tab; on the web, the three-type sum.
  # RLY-148 adds `agent_stalled` to BOTH flavors — a dead agent needs a human wherever
  # the badge renders (the mobile Needs-you tab/feed deliberately stays status-based;
  # revisit with RLY-137).
  defp badge_count(board_row, true = _embed), do: board_row.needs_you_two_type
  defp badge_count(board_row, false = _embed), do: board_row.needs_you_count

  # BOARDS-00's phone-width meta line. Built as one string so the template can't
  # introduce whitespace inside it (the tests assert the exact text).
  defp mobile_meta_label(b) do
    activity = if b.ai_active?, do: "AI active", else: "idle"
    "#{b.stage_count} stages · #{b.card_count} cards · #{activity}"
  end

  defp meta_label(b), do: "#{b.slug} · #{b.card_count} cards"

  # Cosmetic per-board accent from a stable hash of the slug.
  defp accent(slug), do: "oklch(0.62 0.15 #{rem(:erlang.phash2(slug), 360)})"

  defp updated_label(%DateTime{} = at) do
    seconds = DateTime.diff(DateTime.utc_now(), at, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end
end
