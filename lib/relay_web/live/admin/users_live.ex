defmodule RelayWeb.Admin.UsersLive do
  @moduledoc """
  Read-only table of every user at `/admin/users` (RE353): name, email, sign-in provider,
  board count, and created date, newest first. Static snapshot at mount (no PubSub). Gated
  by the `:admin` live_session.
  """
  use RelayWeb, :live_view

  alias Relay.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin · Users")
     |> stream(:users, Accounts.list_users_for_admin(), dom_id: &"admin-user-#{&1.id}")}
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
        <h1 class="mt-2 text-2xl font-semibold">Users</h1>
        <p class="mt-1 text-sm text-base-content/65">Every user, newest first.</p>

        <div class="mt-6 overflow-x-auto rounded-box border border-base-200">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Name</th>
                <th>Email</th>
                <th>Provider</th>
                <th class="text-right">Boards</th>
                <th>Created</th>
              </tr>
            </thead>
            <tbody id="admin-users" phx-update="stream">
              <tr :for={{dom_id, user} <- @streams.users} id={dom_id}>
                <td class="font-medium">{user.name || "—"}</td>
                <td>{user.email}</td>
                <td>{user.provider || "—"}</td>
                <td id={"#{dom_id}-boards"} class="text-right tabular-nums">{user.board_count}</td>
                <td class="font-mono text-xs text-base-content/65">
                  {Calendar.strftime(user.inserted_at, "%Y-%m-%d")}
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
