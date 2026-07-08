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

  MMF 18 makes the board realtime: mount subscribes to `Relay.Events` for this
  board, and handle_info/2 applies the broadcast domain events (card_upserted,
  card_moved, timeline_appended, stages_changed) idempotently to the streams,
  counts, and open drawer — whether the change came from another browser
  session or from the REST API.
  """

  use RelayWeb, :live_view

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Events
  alias Schemas.Card
  alias Schemas.Stage

  @category_order [:unstarted, :in_progress, :complete]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div id="board" phx-hook="BoardDnD">
        <div class="flex items-center justify-between px-4 pb-3 pt-1 sm:px-5">
          <h1 id="board-title" class="text-xl font-semibold">{@board.name}</h1>
          <div class="flex items-center gap-4">
            <div
              class="hidden items-center gap-3 sm:flex"
              style="font-size:11px;font-family:var(--font-mono);color:oklch(0.55 0.02 255);"
            >
              <span class="flex items-center gap-1.5">
                <span style="width:8px;height:8px;border-radius:2px;background:var(--color-secondary);"></span>AI
              </span>
              <span class="flex items-center gap-1.5">
                <span style="width:8px;height:8px;border-radius:2px;background:var(--color-primary);"></span>HUMAN
              </span>
            </div>
            <.link
              navigate={~p"/board/settings"}
              id="board-settings-link"
              class="btn btn-ghost btn-sm btn-circle"
              aria-label="Board settings"
            >
              <.icon name="hero-cog-6-tooth" class="size-5" />
            </.link>
          </div>
        </div>
        <div style="display:flex;gap:22px;padding:16px 18px 18px 18px;overflow-x:auto;overflow-y:hidden;align-items:stretch;background:oklch(0.952 0.008 255);min-height:calc(100vh - 120px);">
          <section
            :for={{category, stages} <- @stage_groups}
            id={"category-#{category}"}
            style="display:flex;flex-direction:column;gap:9px;flex:0 0 auto;"
          >
            <div style="display:flex;align-items:center;gap:8px;padding:0 4px;height:20px;flex:0 0 auto;">
              <span style={category_dot_style(category)}></span>
              <h2
                class="category-band"
                style="font-size:10.5px;font-weight:600;letter-spacing:0.09em;text-transform:uppercase;font-family:var(--font-mono);color:oklch(0.52 0.02 255);margin:0;"
              >
                {category_label(category)}
              </h2>
              <span style="font-size:10.5px;font-family:var(--font-mono);color:oklch(0.68 0.02 255);">
                {category_card_count(category, stages, @stage_counts, @sublanes_by_parent)}
              </span>
            </div>
            <div style="display:flex;gap:9px;align-items:stretch;flex:1;min-height:0;">
              <.stage_column
                :for={stage <- stages}
                id={"stage-col-#{stage.position}"}
                name={stage.name}
                owner={stage.owner}
                category={category}
                stage_id={stage.id}
                collapsed={stage_collapsed?(stage, @stage_counts, @sublanes_by_parent, @force_open)}
                count={Map.fetch!(@stage_counts, stage.id)}
                board_key={@board.key}
                cards={Map.fetch!(@streams, stream_name(stage.id))}
                composing={@composing_stage_id == stage.id}
                compose_form={@compose_form}
                sublanes={
                  for sub <- Map.get(@sublanes_by_parent, stage.id, []) do
                    %{
                      id: sub.id,
                      name: lane_label(sub.lane),
                      lane: sub.lane,
                      owner: sub.owner,
                      count: Map.fetch!(@stage_counts, sub.id),
                      cards: Map.fetch!(@streams, stream_name(sub.id))
                    }
                  end
                }
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
        stage_name={drawer_stage_name(@selected_stage, @board.stages)}
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

    if connected?(socket), do: Events.subscribe(board.id)

    cards_by_stage = board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)

    socket =
      socket
      |> assign(:page_title, board.name)
      |> assign(:board, board)
      |> assign(:stage_groups, group_stages(board.stages))
      |> assign(:stage_counts, stage_counts(board.stages, cards_by_stage))
      |> assign(:sublanes_by_parent, sublanes_by_parent(board.stages))
      |> assign(:force_open, MapSet.new())
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

  # MMF 12c — clicking a collapsed stage/lane strip force-opens it for this
  # session only (a MapSet in the socket; not persisted, not broadcast).
  def handle_event("expand_stage", %{"stage-id" => stage_id}, socket) do
    case parse_int(stage_id) do
      nil -> {:noreply, socket}
      id -> {:noreply, update(socket, :force_open, &MapSet.put(&1, id))}
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

  # MMF 18 — realtime application of Relay.Events broadcasts. Every open
  # session applies every event for its board, including the acting
  # session's own echo: streams upsert by DOM id and counts/stages are
  # recomputed from the DB, so double-apply is a no-op by construction.
  @impl true
  def handle_info({:card_upserted, %Card{} = card}, socket) do
    if find_stage_by_id(socket, card.stage_id) do
      cards_by_stage = socket.assigns.board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)

      {:noreply,
       socket
       |> stream_insert(stream_name(card.stage_id), card)
       |> assign(:stage_counts, stage_counts(socket.assigns.board.stages, cards_by_stage))
       |> maybe_refresh_drawer(card)}
    else
      # The card sits in a stage this socket hasn't loaded yet (e.g. a
      # just-enabled sub-lane racing its stages_changed event): rebuild.
      {:noreply, reload_board(socket)}
    end
  end

  def handle_info({:card_moved, %Card{} = moved, from_stage_id}, socket) do
    if find_stage_by_id(socket, moved.stage_id) do
      {:noreply, apply_move(socket, from_stage_id, moved)}
    else
      {:noreply, reload_board(socket)}
    end
  end

  def handle_info({:timeline_appended, card_id, entry}, socket) do
    case socket.assigns.selected_card do
      %Card{id: ^card_id} -> {:noreply, stream_insert(socket, :timeline, entry)}
      _other -> {:noreply, socket}
    end
  end

  def handle_info({:stages_changed, _board_id}, socket) do
    {:noreply, reload_board(socket)}
  end

  # Groups position-ordered stages under their category, keeping the fixed
  # category order and dropping empty categories (per spec: headers render
  # only for non-empty categories).
  defp group_stages(stages) do
    groups = stages |> Enum.filter(&(&1.lane == :main)) |> Enum.group_by(& &1.category)

    @category_order
    |> Enum.map(&{&1, Map.get(groups, &1, [])})
    |> Enum.reject(fn {_category, category_stages} -> category_stages == [] end)
  end

  # Children grouped under their parent's id, each list ordered Review→Done.
  defp sublanes_by_parent(stages) do
    stages
    |> Enum.filter(&(&1.lane != :main))
    |> Enum.group_by(& &1.parent_id)
    |> Map.new(fn {parent_id, children} -> {parent_id, Enum.sort_by(children, &lane_order/1)} end)
  end

  defp lane_order(%Stage{lane: :review}), do: 0
  defp lane_order(%Stage{lane: :done}), do: 1

  defp lane_label(:review), do: "Review"
  defp lane_label(:done), do: "Done"

  # Streams can't be counted, so lane counts live in their own assign,
  # recomputed from the grouped cards (mount, moves) and bumped on create.
  defp stage_counts(stages, cards_by_stage) do
    Map.new(stages, fn stage -> {stage.id, length(Map.get(cards_by_stage, stage.id, []))} end)
  end

  # MMF 12c — a stage auto-collapses to the mockup's strip only when it is
  # empty across its main lane AND all its sub-lanes, and the user hasn't
  # force-opened it this session (mockup: collapsed = all.length === 0).
  defp stage_collapsed?(%Stage{} = stage, stage_counts, sublanes_by_parent, force_open) do
    total =
      sublanes_by_parent
      |> Map.get(stage.id, [])
      |> Enum.reduce(Map.fetch!(stage_counts, stage.id), fn sub, acc ->
        acc + Map.fetch!(stage_counts, sub.id)
      end)

    total == 0 and not MapSet.member?(force_open, stage.id)
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
  # current one, in position order. Sub-lanes are ordinary move_card
  # targets (per plan Architecture: "no move changes"), but must show a
  # human label ("Code · Review") rather than the composite internal
  # Stage.name ("Code:Review") built by Boards.enable_lane/2 — the same
  # leak lane_label/1 already guards against on the board itself.
  defp move_targets(board, %Card{stage_id: stage_id}) do
    stages_by_id = Map.new(board.stages, &{&1.id, &1})

    board.stages
    |> Enum.reject(&(&1.id == stage_id))
    |> Enum.map(&%{id: &1.id, name: move_target_name(&1, stages_by_id)})
  end

  defp move_target_name(%Stage{lane: :main} = stage, _stages_by_id), do: stage.name

  defp move_target_name(%Stage{parent_id: parent_id} = stage, stages_by_id) do
    parent = Map.fetch!(stages_by_id, parent_id)
    "#{parent.name} · #{lane_label(stage.lane)}"
  end

  # The drawer header chip and "Stage" rail label render whatever stage
  # is selected, including a sub-lane child — sanitize it the same way
  # move_target_name/2 already does for the move menu, so the composite
  # internal Stage.name ("Code:Review") never reaches either spot.
  defp drawer_stage_name(%Stage{} = stage, stages) do
    move_target_name(stage, Map.new(stages, &{&1.id, &1}))
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

  # A remotely upserted card that is open in this session's drawer: sync
  # the drawer assigns (selected card, status form, timeline) through the
  # same refresh_card/2 path local drawer actions use.
  defp maybe_refresh_drawer(socket, %Card{id: id} = card) do
    case socket.assigns.selected_card do
      %Card{id: ^id} -> refresh_card(socket, card)
      _other -> socket
    end
  end

  # stages_changed (or an event for a stage this socket doesn't know yet):
  # refetch the board and rebuild every stage-derived assign and stream,
  # exactly like mount does. Streams reset from the DB, so this is
  # idempotent and safe to run on the acting session's own echo too.
  defp reload_board(socket) do
    board = Boards.get_or_create_default_board(socket.assigns.current_scope.user)
    cards_by_stage = board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)

    socket =
      socket
      |> assign(:board, board)
      |> assign(:stage_groups, group_stages(board.stages))
      |> assign(:stage_counts, stage_counts(board.stages, cards_by_stage))
      |> assign(:sublanes_by_parent, sublanes_by_parent(board.stages))

    board.stages
    |> Enum.reduce(socket, fn stage, acc ->
      stream(acc, stream_name(stage.id), Map.get(cards_by_stage, stage.id, []), reset: true)
    end)
    |> refresh_selected_stage()
  end

  # After a stage reload, re-derive the open drawer's stage from the new
  # board (disable_lane refuses to remove a non-empty lane, so the
  # selected card's stage always still exists).
  defp refresh_selected_stage(socket) do
    case socket.assigns.selected_card do
      %Card{} = card -> assign(socket, :selected_stage, find_stage_by_id(socket, card.stage_id))
      _other -> socket
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

  # The category band's total: every card in the category's main stages plus
  # their Review/Done sub-lanes.
  defp category_card_count(_category, stages, stage_counts, sublanes_by_parent) do
    Enum.reduce(stages, 0, fn stage, acc ->
      sub_total =
        sublanes_by_parent
        |> Map.get(stage.id, [])
        |> Enum.reduce(0, fn sub, sub_acc -> sub_acc + Map.fetch!(stage_counts, sub.id) end)

      acc + Map.fetch!(stage_counts, stage.id) + sub_total
    end)
  end

  # The small colored marker beside each category band, mirroring the mockup's
  # catMeta dots: a hollow ring (unstarted), a half-filled conic (in progress),
  # and a solid green disc (complete).
  defp category_dot_style(:unstarted),
    do:
      "width:9px;height:9px;border-radius:50%;border:1.5px solid oklch(0.68 0.02 255);box-sizing:border-box;display:block;flex:0 0 auto;"

  defp category_dot_style(:in_progress),
    do:
      "width:9px;height:9px;border-radius:50%;background:conic-gradient(var(--color-primary) 0 50%, oklch(0.86 0.03 250) 50% 100%);display:block;flex:0 0 auto;"

  defp category_dot_style(:complete),
    do: "width:9px;height:9px;border-radius:50%;background:var(--color-success);display:block;flex:0 0 auto;"
end
