defmodule HamacaWeb.BoardSwitcherComponent do
  @moduledoc """
  The board bar's board switcher (RE497) — the board name ▾ button and its menu of the user's
  boards. Rendering is `HamacaWeb.BoardBarComponents.board_switcher_menu/1`; this component
  only owns *when* the rows are fetched.

  `Hamaca.Cards.list_board_summaries/1` reads every card of every board, so it must not run on
  every board page mount. The rows are loaded by the `"load"` event the button pushes on open
  — only the first time: once `boards` is set, a later open is a no-op and the menu shows the
  rows cached for this mount. `mount/1` and `update/2` never fetch.
  """
  use HamacaWeb, :live_component

  alias Hamaca.Cards
  alias HamacaWeb.BoardBarComponents

  @impl true
  def mount(socket), do: {:ok, assign(socket, :boards, nil)}

  @impl true
  def handle_event("load", _params, %{assigns: %{boards: nil}} = socket) do
    {:noreply, assign(socket, :boards, Cards.list_board_summaries(socket.assigns.user))}
  end

  def handle_event("load", _params, socket), do: {:noreply, socket}

  # A stateful component needs one static HTML tag at its root, and the markup is a function
  # component shared with the storybook, so a `display: contents` div wraps it. It generates no
  # box, which keeps `#board-switcher` a flex item of the bar's `#top-bar-title`.
  @impl true
  def render(assigns) do
    ~H"""
    <div class="contents">
      <BoardBarComponents.board_switcher_menu board={@board} boards={@boards} target={@myself} />
    </div>
    """
  end
end
