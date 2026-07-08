defmodule RelayWeb.BoardLive do
  @moduledoc """
  The authenticated home (`/board`): the user's board rendered as stage
  columns grouped under category bands (Unstarted → In progress →
  Complete). Cards live in one LiveView stream per stage; each column's
  composer creates cards via `Relay.Cards` (MMF 03).

  MMF 04 adds the URL-driven card detail drawer ("?card=<ref>", handled
  in handle_params/3) rendered via RelayWeb.CoreComponents.card_drawer/1.

  MMF 05 makes cards movable: the BoardDnD drag-and-drop hook and the drawer's "Move to…"
  menu both push a "move_card" event; the server persists via Cards.move_card/3, resets the
  affected stage streams, and keeps the lane counts in sync.
  """

  use RelayWeb, :live_view

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias Schemas.Card
  alias Schemas.Stage

  @category_order [:unstarted, :in_progress, :complete]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div id="board" class="space-y-4" phx-hook="BoardDnD">
        <div class="flex items-center justify-between">
          <h1 id="board-title" class="text-xl font-semibold">{@board.name}</h1>
          <.link
            navigate={~p"/board/settings"}
            id="board-settings-link"
            class="btn btn-ghost btn-sm btn-circle"
            aria-label="Board settings"
          >
            <.icon name="hero-cog-6-tooth" class="size-5" />
          </.link>
        </div>
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
                count={Map.fetch!(@stage_counts, stage.id)}
                board_key={@board.key}
                cards={Map.fetch!(@streams, stream_name(stage.id))}
                composing={@composing_stage_id == stage.id}
                compose_form={@compose_form}
              />
            </div>
          </section>
        </div>
      </div>
      <.card_drawer
        :if={@selected_card}
        id="card-drawer"
        ref={Cards.ref(@board, @selected_card)}
        card={@selected_card}
        stage_name={@selected_stage.name}
        stage_owner={@selected_stage.owner}
        stages={move_targets(@board, @selected_card)}
        active_owner={Cards.active_owner_type(@selected_card)}
        close_patch={~p"/board"}
        title_form={@title_form}
        editing_description={@editing_description}
        description_form={@description_form}
        status_form={@status_form}
        current_user_id={@current_scope.user.id}
        timeline={@streams.timeline}
        comment_form={@comment_form}
      />
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
      |> assign(:stage_counts, stage_counts(board.stages, cards_by_stage))
      |> assign(:composing_stage_id, nil)
      |> assign(:compose_form, empty_compose_form())
      |> stream_configure(:timeline, dom_id: &timeline_dom_id/1)

    socket =
      Enum.reduce(board.stages, socket, fn stage, acc ->
        stream(acc, stream_name(stage.id), Map.get(cards_by_stage, stage.id, []))
      end)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_selected_card(socket, params["card"])}
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

  # Tracks the composer's live value server-side (LiveView only patches the
  # client DOM when a tracked assign's rendered value actually changes). Without
  # this, the server's view of the input is always "" before and after create,
  # so resetting to empty_compose_form/0 in create_card is a no-op diff and the
  # just-submitted text is left showing in the browser.
  def handle_event("validate_card", %{"card" => card_params}, socket) do
    {:noreply, assign(socket, :compose_form, to_form(card_params, as: :card))}
  end

  def handle_event("create_card", %{"stage_id" => stage_id, "card" => card_params}, socket) do
    stage = find_stage(socket, stage_id)

    case stage && Cards.create_card(stage, card_params, current_actor(socket)) do
      nil ->
        {:noreply, socket}

      {:ok, card} ->
        {:noreply,
         socket
         |> stream_insert(stream_name(stage.id), card)
         |> update(:stage_counts, &Map.update!(&1, stage.id, fn count -> count + 1 end))
         |> assign(:compose_form, empty_compose_form())}

      {:error, changeset} ->
        {:noreply, assign(socket, :compose_form, to_form(changeset))}
    end
  end

  def handle_event("select_card", %{"ref" => ref}, socket) do
    {:noreply, push_patch(socket, to: ~p"/board?card=#{ref}")}
  end

  # One move path, two entry points (drag-and-drop hook and the drawer's
  # "Move to…" menu). `index` is the 0-based drop index among the target
  # stage's other cards; when omitted (drawer) the card appends to the
  # bottom. Anything that doesn't resolve on THIS board is a silent no-op.
  def handle_event("move_card", %{"ref" => ref, "stage_id" => stage_id} = params, socket) do
    with %Card{} = card <- Cards.get_card_by_ref(socket.assigns.board, ref),
         %Stage{} = stage <- resolve_stage(socket, stage_id),
         index when is_integer(index) <- resolve_index(params, socket, stage),
         {:ok, moved} <- Cards.move_card(card, stage, index, current_actor(socket)) do
      {:noreply, apply_move(socket, card.stage_id, moved)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("save_card_title", %{"card" => card_params}, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    case Cards.update_card(card, card_params) do
      {:ok, card} ->
        {:noreply,
         socket
         |> assign(:selected_card, card)
         |> assign(:title_form, to_form(%{"title" => card.title}, as: :card))
         |> stream_insert(stream_name(card.stage_id), card)}

      {:error, changeset} ->
        {:noreply, assign(socket, :title_form, to_form(changeset))}
    end
  end

  def handle_event("save_card_title", _params, socket), do: {:noreply, socket}

  def handle_event("edit_description", _params, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    {:noreply,
     socket
     |> assign(:editing_description, true)
     |> assign(:description_form, to_form(%{"description" => card.description || ""}, as: :card))}
  end

  def handle_event("edit_description", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_description", _params, socket) do
    {:noreply, assign(socket, editing_description: false, description_form: nil)}
  end

  def handle_event(
        "save_card_description",
        %{"card" => card_params},
        %{assigns: %{selected_card: %Card{} = card}} = socket
      ) do
    case Cards.update_card(card, card_params) do
      {:ok, card} ->
        {:noreply,
         socket
         |> assign(:selected_card, card)
         |> assign(:editing_description, false)
         |> assign(:description_form, nil)
         |> stream_insert(stream_name(card.stage_id), card)}

      {:error, changeset} ->
        {:noreply, assign(socket, :description_form, to_form(changeset))}
    end
  end

  def handle_event("save_card_description", _params, socket), do: {:noreply, socket}

  def handle_event("set_card_status", %{"card" => card_params}, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    case Cards.set_status(card, card_params, current_actor(socket)) do
      {:ok, card} ->
        {:noreply, refresh_card(socket, card)}

      {:error, changeset} ->
        {:noreply, assign(socket, :status_form, to_form(changeset))}
    end
  end

  def handle_event("set_card_status", _params, socket), do: {:noreply, socket}

  # Owner changes are explicit drawer actions. Adding a :user owner is
  # restricted to the signed-in user (MVP boards are single-human; members
  # arrive in MMF 17); anything unresolvable is a silent no-op.
  def handle_event("add_owner", params, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    current_user_id = socket.assigns.current_scope.user.id

    case resolve_actor(params) do
      :agent ->
        apply_owner_change(socket, Cards.add_owner(card, :agent, current_actor(socket)))

      {:user, ^current_user_id} = actor ->
        apply_owner_change(socket, Cards.add_owner(card, actor, current_actor(socket)))

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("add_owner", _params, socket), do: {:noreply, socket}

  def handle_event("remove_owner", params, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    case resolve_actor(params) do
      nil -> {:noreply, socket}
      actor -> apply_owner_change(socket, Cards.remove_owner(card, actor, current_actor(socket)))
    end
  end

  def handle_event("remove_owner", _params, socket), do: {:noreply, socket}

  def handle_event("validate_comment", %{"comment" => comment_params}, socket) do
    {:noreply, assign(socket, :comment_form, to_form(comment_params, as: :comment))}
  end

  def handle_event("post_comment", %{"comment" => comment_params}, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    case Activity.add_comment(card, %{actor: current_actor(socket), body: comment_params["body"]}) do
      {:ok, comment} ->
        {:noreply,
         socket
         |> stream_insert(:timeline, comment)
         |> assign(:comment_form, empty_comment_form())}

      {:error, changeset} ->
        {:noreply, assign(socket, :comment_form, to_form(changeset))}
    end
  end

  def handle_event("post_comment", _params, socket), do: {:noreply, socket}

  # Groups position-ordered stages under their category, keeping the fixed
  # category order and dropping empty categories (per spec: headers render
  # only for non-empty categories).
  defp group_stages(stages) do
    groups = Enum.group_by(stages, & &1.category)

    @category_order
    |> Enum.map(&{&1, Map.get(groups, &1, [])})
    |> Enum.reject(fn {_category, category_stages} -> category_stages == [] end)
  end

  # Streams can't be counted, so lane counts live in their own assign,
  # recomputed from the grouped cards (mount, moves) and bumped on create.
  defp stage_counts(stages, cards_by_stage) do
    Map.new(stages, fn stage -> {stage.id, length(Map.get(cards_by_stage, stage.id, []))} end)
  end

  # Only stages of the user's own board are addressable from events.
  # Every action taken in this LiveView is attributed to the signed-in
  # human; the :agent default on the Cards mutators is the API's (MMF 09).
  defp current_actor(socket), do: {:user, socket.assigns.current_scope.user.id}

  defp find_stage(socket, stage_id) do
    find_stage_by_id(socket, String.to_integer(stage_id))
  end

  defp find_stage_by_id(socket, stage_id) do
    Enum.find(socket.assigns.board.stages, &(&1.id == stage_id))
  end

  # Drawer move targets: every stage on this board except the card's
  # current one, in position order.
  defp move_targets(board, %Card{stage_id: stage_id}) do
    Enum.reject(board.stages, &(&1.id == stage_id))
  end

  defp resolve_stage(socket, stage_id) do
    case parse_int(stage_id) do
      nil -> nil
      id -> find_stage_by_id(socket, id)
    end
  end

  # The drop index from the DnD hook; the drawer omits it, meaning
  # "append to the bottom" — the target's current count clamps to the
  # last slot inside Cards.move_card/3.
  defp resolve_index(%{"index" => index}, _socket, _stage), do: parse_int(index)
  defp resolve_index(_params, socket, stage), do: Map.fetch!(socket.assigns.stage_counts, stage.id)

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_value), do: nil

  defp resolve_actor(%{"actor_type" => "agent"}), do: :agent

  defp resolve_actor(%{"actor_type" => "user", "user_id" => user_id}) do
    case parse_int(user_id) do
      nil -> nil
      id -> {:user, id}
    end
  end

  defp resolve_actor(_params), do: nil

  defp apply_owner_change(socket, {:ok, %Card{} = card}), do: {:noreply, refresh_card(socket, card)}
  defp apply_owner_change(socket, {:error, _changeset}), do: {:noreply, socket}

  # A persisted baton change: sync the drawer assigns and re-stream the
  # card so the board card re-renders its colour/badge.
  defp refresh_card(socket, %Card{} = card) do
    socket
    |> assign(:selected_card, card)
    |> assign(:status_form, status_form(card))
    |> stream(:timeline, Activity.list_timeline(card), reset: true)
    |> stream_insert(stream_name(card.stage_id), card)
  end

  defp status_form(%Card{} = card) do
    to_form(%{"status" => Atom.to_string(card.status), "progress" => card.progress}, as: :card)
  end

  # The move already persisted; stream items can't be reordered in
  # place, so refetch and reset the source and target stage streams,
  # refresh the lane counts, and keep the drawer in sync when the moved
  # card is the selected one.
  defp apply_move(socket, source_stage_id, %Card{} = moved) do
    cards_by_stage = socket.assigns.board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)

    socket
    |> restream_stage(source_stage_id, cards_by_stage)
    |> restream_stage(moved.stage_id, cards_by_stage)
    |> assign(:stage_counts, stage_counts(socket.assigns.board.stages, cards_by_stage))
    |> refresh_selected_after_move(moved)
  end

  defp restream_stage(socket, stage_id, cards_by_stage) do
    stream(socket, stream_name(stage_id), Map.get(cards_by_stage, stage_id, []), reset: true)
  end

  defp refresh_selected_after_move(socket, %Card{} = moved) do
    moved_id = moved.id

    case socket.assigns.selected_card do
      %Card{id: ^moved_id} ->
        socket
        |> assign(:selected_card, moved)
        |> assign(:selected_stage, find_stage_by_id(socket, moved.stage_id))
        |> stream(:timeline, Activity.list_timeline(moved), reset: true)

      _ ->
        socket
    end
  end

  # The drawer is URL-driven: ?card=<ref> selects a card; no param — or a
  # ref that doesn't resolve on this user's board (unknown, malformed, or
  # another board's card) — means no drawer. Authorization is the board
  # scoping inside Cards.get_card_by_ref/2.
  defp assign_selected_card(socket, ref) do
    card = if ref, do: Cards.get_card_by_ref(socket.assigns.board, ref)

    case card do
      %Card{} = card ->
        socket
        |> assign(:selected_card, card)
        |> assign(:selected_stage, find_stage_by_id(socket, card.stage_id))
        |> assign(:title_form, to_form(%{"title" => card.title}, as: :card))
        |> assign(:editing_description, false)
        |> assign(:description_form, nil)
        |> assign(:status_form, status_form(card))
        |> assign(:comment_form, empty_comment_form())
        |> stream(:timeline, Activity.list_timeline(card), reset: true)

      nil ->
        socket
        |> assign(
          selected_card: nil,
          selected_stage: nil,
          title_form: nil,
          editing_description: false,
          description_form: nil,
          status_form: nil,
          comment_form: nil
        )
        |> stream(:timeline, [], reset: true)
    end
  end

  # Streams are keyed per stage so each column gets its own
  # phx-update="stream" container. Stage ids come from this user's board
  # rows (a small, trusted set), not from user input, so building one atom
  # per stage is safe.
  # sobelow_skip ["DOS.BinToAtom"]
  defp stream_name(stage_id), do: :"stage_cards_#{stage_id}"

  defp empty_compose_form, do: to_form(%{"title" => ""}, as: :card)

  defp empty_comment_form, do: to_form(%{"body" => ""}, as: :comment)

  defp timeline_dom_id(%Schemas.Comment{id: id}), do: "timeline-comment-#{id}"
  defp timeline_dom_id(%Schemas.Activity{id: id}), do: "timeline-activity-#{id}"

  defp category_label(:unstarted), do: "Unstarted"
  defp category_label(:in_progress), do: "In progress"
  defp category_label(:complete), do: "Complete"
end
