defmodule RelayWeb.Admin.IndexLive do
  @moduledoc """
  The `/admin` landing page (RE353): links to the superadmin-only admin pages. Gated like
  every `/admin` route — the `:require_superadmin_user` pipeline plus the `:admin`
  live_session's `{RelayWeb.Auth, :require_superadmin}` on_mount.
  """
  use RelayWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    pages = [
      %{
        id: "admin-page-boards",
        label: "Boards",
        path: ~p"/admin/boards",
        description: "Every board, archived included, with owner and member/card counts."
      },
      %{
        id: "admin-page-users",
        label: "Users",
        path: ~p"/admin/users",
        description: "Every user, with sign-in provider and board count."
      },
      %{
        id: "admin-page-api",
        label: "API log",
        path: ~p"/admin/api",
        description: "Live view of the last 200 inbound API requests."
      }
    ]

    {:ok, socket |> assign(:page_title, "Admin") |> assign(:pages, pages)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-5xl px-4 py-8">
        <h1 class="text-2xl font-semibold">Admin</h1>
        <p class="mt-1 text-sm text-base-content/65">
          Superadmin-only views across every board and user.
        </p>

        <ul class="mt-6 overflow-hidden rounded-box border border-base-200 divide-y divide-base-200">
          <li :for={page <- @pages}>
            <.link navigate={page.path} id={page.id} class="block px-4 py-3 hover:bg-base-200/60">
              <span class="font-medium">{page.label}</span>
              <span class="block text-sm text-base-content/65">{page.description}</span>
            </.link>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
