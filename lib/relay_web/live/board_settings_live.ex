defmodule RelayWeb.BoardSettingsLive do
  @moduledoc """
  Board settings (`/board/settings`) — the first settings surface (MMF 08;
  MMF 12 stage config and MMF 10b sub-lane toggles extend this page).

  Hosts the API key pane: generate / regenerate / revoke the board's single
  key via `Relay.ApiKeys`. The raw secret lives only in the `:revealed_token`
  assign for the mount that created it — shown exactly once, never
  re-retrievable. Authorization is inherent: everything operates on the
  current user's own board.
  """

  use RelayWeb, :live_view

  alias Relay.ApiKeys
  alias Relay.Boards

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl space-y-6">
        <div class="flex items-center gap-2">
          <.link
            navigate={~p"/board"}
            id="back-to-board"
            class="btn btn-ghost btn-sm btn-circle"
            aria-label="Back to board"
          >
            <.icon name="hero-arrow-left" class="size-4" />
          </.link>
          <h1 id="settings-title" class="text-xl font-semibold">Board settings</h1>
        </div>

        <section id="api-key-pane" class="card border border-base-300 bg-base-100">
          <div class="card-body space-y-4">
            <div>
              <h2 class="card-title text-base">API key</h2>
              <p class="text-sm text-base-content/60">
                Lets external tools (like Claude Code) act on this board. One key per board.
              </p>
            </div>

            <div :if={@revealed_token} id="api-key-reveal" class="space-y-2">
              <div id="api-key-reveal-note" class="alert alert-warning text-sm">
                <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
                <span>Copy this key now — you won't be able to see it again.</span>
              </div>
              <div class="join w-full">
                <code
                  id="api-key-secret"
                  class="join-item flex flex-1 items-center overflow-x-auto border border-base-300 bg-base-200 px-3 py-2 font-mono text-sm"
                >
                  {@revealed_token}
                </code>
                <button
                  id="copy-key"
                  type="button"
                  class="join-item btn btn-primary"
                  phx-hook=".CopyKey"
                  data-target="api-key-secret"
                >
                  <.icon name="hero-clipboard" class="size-4" /> Copy
                </button>
              </div>
              <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyKey">
                export default {
                  mounted() {
                    this.el.addEventListener("click", () => {
                      const target = document.getElementById(this.el.dataset.target)
                      if (target) navigator.clipboard.writeText(target.textContent.trim())
                    })
                  }
                }
              </script>
            </div>

            <%= if @api_key do %>
              <dl id="api-key-details" class="grid grid-cols-[auto_1fr] gap-x-6 gap-y-1 text-sm">
                <dt class="text-base-content/60">Name</dt>
                <dd id="api-key-name">{@api_key.name}</dd>
                <dt class="text-base-content/60">Key</dt>
                <dd id="api-key-masked" class="font-mono">{masked(@api_key)}</dd>
                <dt class="text-base-content/60">Created</dt>
                <dd id="api-key-created">{format_time(@api_key.inserted_at)}</dd>
                <dt class="text-base-content/60">Last used</dt>
                <dd id="api-key-last-used">{last_used(@api_key)}</dd>
              </dl>
              <div class="card-actions">
                <button
                  id="regenerate-key"
                  class="btn btn-outline btn-sm"
                  phx-click="regenerate_key"
                  data-confirm="Regenerate the key? The current key stops working immediately."
                >
                  <.icon name="hero-arrow-path" class="size-4" /> Regenerate
                </button>
                <button
                  id="revoke-key"
                  class="btn btn-outline btn-error btn-sm"
                  phx-click="revoke_key"
                  data-confirm="Revoke the key? Tools using it will lose access."
                >
                  <.icon name="hero-trash" class="size-4" /> Revoke
                </button>
              </div>
            <% else %>
              <div class="card-actions">
                <button id="generate-key" class="btn btn-primary btn-sm" phx-click="generate_key">
                  <.icon name="hero-key" class="size-4" /> Generate key
                </button>
              </div>
            <% end %>
          </div>
        </section>

        <section id="stages-pane" class="card border border-base-300 bg-base-100">
          <div class="card-body space-y-4">
            <div>
              <h2 class="card-title text-base">Stages</h2>
              <p class="text-sm text-base-content/60">
                Add a Review or Done sub-lane to a stage. A Review lane is for humans; a Done lane matches the stage.
              </p>
            </div>
            <ul class="divide-y divide-base-200">
              <li
                :for={stage <- @stages}
                id={"stage-#{stage.id}-row"}
                class="flex items-center justify-between py-2"
              >
                <span class="text-sm font-medium">{stage.name}</span>
                <div class="flex items-center gap-4">
                  <label class="flex items-center gap-2 text-xs">
                    <input
                      id={"stage-#{stage.id}-review-toggle"}
                      type="checkbox"
                      class="toggle toggle-sm"
                      checked={lane_on?(@lane_map, stage.id, :review)}
                      phx-click="toggle_lane"
                      phx-value-stage-id={stage.id}
                      phx-value-lane="review"
                    /> Review
                  </label>
                  <label class="flex items-center gap-2 text-xs">
                    <input
                      id={"stage-#{stage.id}-done-toggle"}
                      type="checkbox"
                      class="toggle toggle-sm"
                      checked={lane_on?(@lane_map, stage.id, :done)}
                      phx-click="toggle_lane"
                      phx-value-stage-id={stage.id}
                      phx-value-lane="done"
                    /> Done
                  </label>
                </div>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    board = Boards.get_or_create_default_board(socket.assigns.current_scope.user)

    {:ok,
     socket
     |> assign(:page_title, "Board settings")
     |> assign(:board, board)
     |> assign(:api_key, ApiKeys.get_key(board))
     |> assign(:revealed_token, nil)
     |> assign(:stages, board |> Boards.list_stages() |> Enum.filter(&(&1.lane == :main)))
     |> assign(:lane_map, lane_map(board))}
  end

  @impl true
  def handle_event("generate_key", _params, socket) do
    case ApiKeys.create_key(socket.assigns.board, socket.assigns.current_scope.user) do
      {:ok, %{api_key: key, token: token}} ->
        {:noreply, socket |> assign(:api_key, key) |> assign(:revealed_token, token)}

      {:error, :already_exists} ->
        {:noreply,
         socket
         |> put_flash(:error, "This board already has an API key.")
         |> assign(:api_key, ApiKeys.get_key(socket.assigns.board))}
    end
  end

  def handle_event("regenerate_key", _params, socket) do
    {:ok, %{api_key: key, token: token}} = ApiKeys.regenerate(socket.assigns.api_key)
    {:noreply, socket |> assign(:api_key, key) |> assign(:revealed_token, token)}
  end

  def handle_event("revoke_key", _params, socket) do
    {:ok, _key} = ApiKeys.revoke(socket.assigns.api_key)

    {:noreply,
     socket
     |> assign(:api_key, nil)
     |> assign(:revealed_token, nil)
     |> put_flash(:info, "API key revoked.")}
  end

  def handle_event("toggle_lane", %{"stage-id" => stage_id, "lane" => lane}, socket) do
    lane = lane_atom(lane)
    stage = Enum.find(socket.assigns.stages, &(&1.id == String.to_integer(stage_id)))

    result =
      if lane_on?(socket.assigns.lane_map, stage.id, lane) do
        Boards.disable_lane(stage, lane)
      else
        Boards.enable_lane(stage, lane)
      end

    {:noreply, apply_lane_result(socket, result)}
  end

  defp lane_atom("review"), do: :review
  defp lane_atom("done"), do: :done

  defp apply_lane_result(socket, {:error, :not_empty}) do
    put_flash(socket, :error, "That lane still has cards — move them out first.")
  end

  defp apply_lane_result(socket, {:ok, _}) do
    board = socket.assigns.board
    assign(socket, :lane_map, lane_map(board))
  end

  defp lane_map(board) do
    board
    |> Boards.list_stages()
    |> Enum.filter(&(&1.lane != :main))
    |> Enum.group_by(& &1.parent_id, & &1.lane)
    |> Map.new(fn {parent_id, lanes} -> {parent_id, MapSet.new(lanes)} end)
  end

  defp lane_on?(lane_map, stage_id, lane), do: MapSet.member?(Map.get(lane_map, stage_id, MapSet.new()), lane)

  defp masked(key), do: "relay_#{key.token_prefix}_…#{key.last_four}"

  defp last_used(%{last_used_at: nil}), do: "Never"
  defp last_used(%{last_used_at: at}), do: format_time(at)

  defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%b %d, %Y, %H:%M UTC")
end
