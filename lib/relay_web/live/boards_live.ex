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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div id="boards-home" class="mx-auto max-w-[1120px] px-7 py-9">
        <div class="flex items-start justify-between gap-5">
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
        <p class="mb-7 mt-1 max-w-[560px] text-sm leading-relaxed" style="color:oklch(0.50 0.02 255);">
          Each board is a shared workspace where you and Relay AI pass work between each other.
        </p>

        <div class="grid gap-4" style="grid-template-columns:repeat(auto-fill,minmax(324px,1fr));">
          <.link
            :for={b <- @boards}
            id={"board-card-#{b.slug}"}
            navigate={~p"/board/#{b.slug}"}
            class="flex flex-col overflow-hidden rounded-[14px] border bg-base-100 no-underline transition hover:-translate-y-0.5"
            style="border-color:oklch(0.90 0.006 255);"
          >
            <div style={"height:3px;background:#{accent(b.slug)};"}></div>
            <div class="flex flex-col gap-2.5 p-4">
              <div class="flex items-center gap-2.5">
                <span
                  class="flex size-[22px] flex-none items-center justify-center rounded-[7px]"
                  style={"background:#{accent(b.slug)};"}
                >
                  <span class="size-[7px] rounded-full bg-white"></span>
                </span>
                <span
                  class="text-[15.5px] font-semibold tracking-tight"
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
              </div>
              <span class="font-mono text-[11.5px]" style="color:oklch(0.58 0.02 255);">
                {meta_label(b)}
              </span>
              <span class="font-mono text-[10.5px]" style="color:oklch(0.62 0.02 255);">
                Updated {updated_label(b.updated_at)}
              </span>
            </div>
          </.link>

          <button
            id="new-board-button"
            type="button"
            phx-click="new_board"
            class="flex min-h-[220px] flex-col items-center justify-center gap-2.5 rounded-[14px] border border-dashed bg-transparent"
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
      %{
        slug: board.slug,
        name: board.name,
        updated_at: board.updated_at,
        card_count: length(Cards.list_cards(board))
      }
    end
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
