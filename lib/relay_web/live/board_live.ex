defmodule RelayWeb.BoardLive do
  @moduledoc """
  The authenticated home (`/board`): the user's board rendered as stage
  columns grouped under category bands (Unstarted → In progress →
  Complete). Read-only in MMF 02 — cards arrive in MMF 03.
  """

  use RelayWeb, :live_view

  alias Relay.Boards

  @category_order [:unstarted, :in_progress, :complete]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div id="board" class="space-y-4">
        <h1 id="board-title" class="text-xl font-semibold">{@board.name}</h1>
        <div class="flex items-start gap-6 overflow-x-auto pb-4">
          <section
            :for={{category, stages} <- @stage_groups}
            id={"category-#{category}"}
            class="shrink-0 space-y-2"
          >
            <h2 class="category-band px-1 text-xs font-semibold uppercase tracking-wider text-base-content/60">
              {category_label(category)}
            </h2>
            <div class="flex items-start gap-4">
              <.stage_column
                :for={stage <- stages}
                id={"stage-col-#{stage.position}"}
                name={stage.name}
                owner={stage.owner}
              />
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    board = Boards.get_or_create_default_board(socket.assigns.current_scope.user)

    {:ok,
     socket
     |> assign(:page_title, board.name)
     |> assign(:board, board)
     |> assign(:stage_groups, group_stages(board.stages))}
  end

  # Groups position-ordered stages under their category, keeping the fixed
  # category order and dropping empty categories (per spec: headers render
  # only for non-empty categories).
  defp group_stages(stages) do
    groups = Enum.group_by(stages, & &1.category)

    @category_order
    |> Enum.map(&{&1, Map.get(groups, &1, [])})
    |> Enum.reject(fn {_category, category_stages} -> category_stages == [] end)
  end

  defp category_label(:unstarted), do: "Unstarted"
  defp category_label(:in_progress), do: "In progress"
  defp category_label(:complete), do: "Complete"
end
