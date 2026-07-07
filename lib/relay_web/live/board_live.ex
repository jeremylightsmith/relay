defmodule RelayWeb.BoardLive do
  @moduledoc """
  The authenticated home (`/board`): the user's board rendered as stage
  columns grouped under category bands (Unstarted → In progress →
  Complete). Cards live in one LiveView stream per stage; each column's
  composer creates cards via `Relay.Cards` (MMF 03).
  """

  use RelayWeb, :live_view

  alias Relay.Boards
  alias Relay.Cards

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
                stage_id={stage.id}
                board_key={@board.key}
                cards={Map.fetch!(@streams, stream_name(stage.id))}
                composing={@composing_stage_id == stage.id}
                compose_form={@compose_form}
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
    cards_by_stage = board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)

    socket =
      socket
      |> assign(:page_title, board.name)
      |> assign(:board, board)
      |> assign(:stage_groups, group_stages(board.stages))
      |> assign(:composing_stage_id, nil)
      |> assign(:compose_form, empty_compose_form())

    socket =
      Enum.reduce(board.stages, socket, fn stage, acc ->
        stream(acc, stream_name(stage.id), Map.get(cards_by_stage, stage.id, []))
      end)

    {:ok, socket}
  end

  @impl true
  def handle_event("compose", %{"stage-id" => stage_id}, socket) do
    {:noreply,
     socket
     |> assign(:composing_stage_id, String.to_integer(stage_id))
     |> assign(:compose_form, empty_compose_form())}
  end

  def handle_event("cancel_compose", _params, socket) do
    {:noreply, assign(socket, :composing_stage_id, nil)}
  end

  def handle_event("create_card", %{"stage_id" => stage_id, "card" => card_params}, socket) do
    stage = find_stage(socket, stage_id)

    case stage && Cards.create_card(stage, card_params) do
      nil ->
        {:noreply, socket}

      {:ok, card} ->
        {:noreply,
         socket
         |> stream_insert(stream_name(stage.id), card)
         |> assign(:compose_form, empty_compose_form())}

      {:error, changeset} ->
        {:noreply, assign(socket, :compose_form, to_form(changeset))}
    end
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

  # Only stages of the user's own board are addressable from events.
  defp find_stage(socket, stage_id) do
    stage_id = String.to_integer(stage_id)
    Enum.find(socket.assigns.board.stages, &(&1.id == stage_id))
  end

  # Streams are keyed per stage so each column gets its own
  # phx-update="stream" container. Stage ids come from this user's board
  # rows (a small, trusted set), not from user input, so building one atom
  # per stage is safe.
  # sobelow_skip ["DOS.BinToAtom"]
  defp stream_name(stage_id), do: :"stage_cards_#{stage_id}"

  defp empty_compose_form, do: to_form(%{"title" => ""}, as: :card)

  defp category_label(:unstarted), do: "Unstarted"
  defp category_label(:in_progress), do: "In progress"
  defp category_label(:complete), do: "Complete"
end
