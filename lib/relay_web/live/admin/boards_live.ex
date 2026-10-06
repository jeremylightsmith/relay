defmodule RelayWeb.Admin.BoardsLive do
  @moduledoc """
  Read-only table of every board at `/admin/boards` (RE353): name, key, owner email, member
  count, card count, created date, and an "Archived" badge — archived boards included,
  A–Z by name (no stars: this isn't a personal list). A board's name links to `/board/:slug` only when the current superadmin is
  already a member; board access rules are unchanged (no bypass). Static snapshot at mount
  (no PubSub). Gated by the `:admin` live_session.
  """
  use RelayWeb, :live_view

  alias Relay.Boards

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin · Boards")
     |> assign(:member_ids, Boards.member_board_ids(socket.assigns.current_scope.user))
     |> stream(:boards, Boards.list_all_boards_for_admin(), dom_id: &"admin-board-#{&1.id}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-5xl px-4 py-8">
        <.link
          navigate={~p"/admin"}
          id="admin-back"
          class="text-sm text-base-content/65 link link-hover"
        >
          ← Admin
        </.link>
        <h1 class="mt-2 text-2xl font-semibold">Boards</h1>
        <p class="mt-1 text-sm text-base-content/65">
          Every board, archived included, A–Z by name. Names link only to boards you're a member of.
        </p>

        <div class="mt-6 overflow-x-auto rounded-box border border-base-200">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Name</th>
                <th>Key</th>
                <th>Owner</th>
                <th class="text-right">Members</th>
                <th class="text-right">Cards</th>
                <th>Created</th>
              </tr>
            </thead>
            <tbody id="admin-boards" phx-update="stream">
              <tr :for={{dom_id, board} <- @streams.boards} id={dom_id}>
                <td>
                  <.link
                    :if={MapSet.member?(@member_ids, board.id)}
                    navigate={~p"/board/#{board.slug}"}
                    class="link link-hover font-medium"
                  >
                    {board.name}
                  </.link>
                  <span :if={!MapSet.member?(@member_ids, board.id)} class="font-medium">
                    {board.name}
                  </span>
                  <span :if={board.archived_at} class="badge badge-sm badge-ghost ml-2">
                    Archived
                  </span>
                </td>
                <td class="font-mono">{board.key}</td>
                <td>{board.owner_email || "—"}</td>
                <td id={"#{dom_id}-members"} class="text-right tabular-nums">{board.member_count}</td>
                <td id={"#{dom_id}-cards"} class="text-right tabular-nums">{board.card_count}</td>
                <td class="font-mono text-xs text-base-content/65">
                  {Calendar.strftime(board.inserted_at, "%Y-%m-%d")}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
