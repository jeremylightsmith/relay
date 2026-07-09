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
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Stage

  @category_order [:unstarted, :planning, :in_progress, :complete]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div id="board" phx-hook="BoardDnD">
        <div
          :if={@read_only?}
          id="read-only-banner"
          class="mx-4 mb-2 mt-2 flex items-center gap-3 rounded-lg px-4 py-2.5 text-sm sm:mx-5"
          style="background:oklch(0.97 0.04 85);border:1px solid oklch(0.85 0.09 85);color:oklch(0.42 0.09 85);"
        >
          <.icon name="hero-archive-box" class="size-4" />
          <span class="flex-1">This board is archived and read-only.</span>
          <button type="button" id="restore-board-button" phx-click="restore_board" class="btn btn-sm">
            Restore
          </button>
        </div>
        <div class="flex items-center justify-between px-4 pb-3 pt-1 sm:px-5">
          <div class="flex items-center gap-2">
            <.link
              navigate={~p"/boards?from=#{@board.slug}"}
              id="all-boards-link"
              title="All boards"
              class="btn btn-ghost btn-sm btn-circle"
              aria-label="All boards"
            >
              <.icon name="hero-squares-2x2" class="size-5" />
            </.link>
            <h1 id="board-title" class="text-xl font-semibold">{@board.name}</h1>
          </div>
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
              navigate={~p"/board/#{@board.slug}/settings"}
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
              <span class="category-dot" style={category_dot_style(category)}></span>
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
                wip_limit={stage.wip_limit}
                board_key={@board.key}
                cards={Map.fetch!(@streams, stream_name(stage.id))}
                composing={@composing_stage_id == stage.id}
                compose_form={@compose_form}
                read_only={@read_only?}
                sublanes={
                  for sub <- Map.get(@sublanes_by_parent, stage.id, []) do
                    %{
                      id: sub.id,
                      name: lane_label(sub.lane),
                      lane: sub.lane,
                      owner: sub.owner,
                      count: Map.fetch!(@stage_counts, sub.id),
                      cards: Map.fetch!(@streams, stream_name(sub.id)),
                      collapsed: sublane_collapsed?(sub, @stage_counts, @force_open)
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
        close_patch={~p"/board/#{@board.slug}"}
        title_form={@title_form}
        editing_title={@editing_title}
        editing_description={@editing_description}
        description_form={@description_form}
        status_form={@status_form}
        current_user_id={@current_scope.user.id}
        conversation={@streams.conversation}
        activity={@streams.activity}
        comment_form={@comment_form}
        question={@question}
        answer_form={@answer_form}
        review_gate={@review_gate}
        reject_open={@reject_open}
        reject_form={@reject_form}
        reject_error={@reject_error}
        send_back_open={@send_back_open}
        send_back_form={@send_back_form}
        send_back_error={@send_back_error}
        send_back_targets={send_back_targets(@board, @selected_card)}
      />
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    board = Boards.get_board!(socket.assigns.current_scope.user, slug)

    if connected?(socket), do: Events.subscribe(board.id)

    cards_by_stage = board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)

    socket =
      socket
      |> assign(:page_title, board.name)
      |> assign(:board, board)
      |> assign(:read_only?, Board.archived?(board))
      |> assign(:stage_groups, group_stages(board.stages))
      |> assign(:stage_counts, stage_counts(board.stages, cards_by_stage))
      |> assign(:sublanes_by_parent, sublanes_by_parent(board.stages))
      |> assign(:force_open, MapSet.new())
      |> assign(:composing_stage_id, nil)
      |> assign(:compose_form, empty_compose_form())
      |> stream_configure(:conversation, dom_id: &conversation_dom_id/1)
      |> stream_configure(:activity, dom_id: &activity_dom_id/1)

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
  def handle_event(event, _params, %{assigns: %{read_only?: true}} = socket) when event in ~w(
        compose create_card move_card save_card_title save_card_description
        set_card_status add_owner remove_owner post_comment answer_input
        review_approve review_reject review_mark_done review_pull send_back
      ) do
    {:noreply, put_flash(socket, :error, "This board is archived (read-only).")}
  end

  def handle_event("restore_board", _params, socket) do
    {:ok, _board} = Boards.unarchive_board(socket.assigns.board)
    {:noreply, reload_board(socket)}
  end

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
         |> stream_insert(stream_name(stage.id), card, at: 0)
         |> update(:stage_counts, &Map.update!(&1, stage.id, fn count -> count + 1 end))
         |> assign(:compose_form, empty_compose_form())
         |> push_event("focus_card", %{ref: Cards.ref(socket.assigns.board, card)})}

      {:error, changeset} ->
        {:noreply, assign(socket, :compose_form, to_form(changeset))}
    end
  end

  def handle_event("select_card", %{"ref" => ref}, socket) do
    {:noreply, push_patch(socket, to: ~p"/board/#{socket.assigns.board.slug}?card=#{ref}")}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/board/#{socket.assigns.board.slug}")}
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
      {:noreply, socket |> apply_move(card.stage_id, moved) |> maybe_warn_over_wip(stage, card.stage_id)}
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

  def handle_event("edit_title", _params, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    {:noreply,
     socket
     |> assign(:editing_title, true)
     |> assign(:title_form, to_form(%{"title" => card.title}, as: :card))}
  end

  def handle_event("edit_title", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_title", _params, socket) do
    {:noreply, assign(socket, :editing_title, false)}
  end

  def handle_event("save_card_title", %{"card" => card_params}, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    case Cards.update_card(card, card_params) do
      {:ok, card} ->
        {:noreply,
         socket
         |> assign(:selected_card, card)
         |> assign(:editing_title, false)
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
         |> stream_insert(:conversation, comment)
         |> assign(:comment_form, empty_comment_form())}

      {:error, changeset} ->
        {:noreply, assign(socket, :comment_form, to_form(changeset))}
    end
  end

  def handle_event("post_comment", _params, socket), do: {:noreply, socket}

  # MMF 14 — the drawer's amber panel submits the human's answer: log it,
  # return the baton (working on an AI-meant stage, queued otherwise), and
  # clear the block. Attributed to the signed-in user; refresh_card re-streams
  # the board card so the amber badge flips off (and MMF 18 broadcasts do the
  # same everywhere else).
  def handle_event(
        "answer_input",
        %{"answer" => %{"body" => body}},
        %{assigns: %{selected_card: %Card{status: :needs_input} = card}} = socket
      ) do
    case Cards.answer_input(card, body, current_actor(socket)) do
      {:ok, card} -> {:noreply, refresh_card(socket, card)}
      {:error, _changeset} -> {:noreply, socket}
    end
  end

  def handle_event("answer_input", _params, socket), do: {:noreply, socket}

  # MMF 15 — the drawer's green review panel: the four human review actions,
  # each a thin wrapper over an existing context transition (Cards.approve/
  # reject from MMF 13, set_status/add_owner from MMF 06), attributed to the
  # signed-in user. Approve/reject move the card, so the acting session
  # re-streams the source and target columns synchronously; MMF 18 echoes
  # keep every other session in sync.
  def handle_event("review_approve", _params, %{assigns: %{selected_card: %Card{status: :in_review} = card}} = socket) do
    case Cards.approve(card, current_actor(socket)) do
      {:ok, updated} -> {:noreply, refresh_after_review(socket, card, updated)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("review_approve", _params, socket), do: {:noreply, socket}

  def handle_event("review_open_reject", _params, socket) do
    {:noreply, assign(socket, reject_open: true, reject_form: empty_reject_form(), reject_error: nil)}
  end

  def handle_event("review_cancel_reject", _params, socket) do
    {:noreply, assign(socket, reject_open: false, reject_error: nil)}
  end

  def handle_event(
        "review_reject",
        %{"reject" => %{"note" => note} = params},
        %{assigns: %{selected_card: %Card{status: :in_review} = card}} = socket
      ) do
    if String.trim(note) == "" do
      {:noreply,
       assign(socket,
         reject_form: to_form(params, as: :reject),
         reject_error: "Add a note — the AI needs to know what to change."
       )}
    else
      opts =
        case resolve_stage(socket, params["to"]) do
          %Stage{} = target -> [to: target]
          nil -> []
        end

      case Cards.reject(card, note, current_actor(socket), opts) do
        {:ok, updated} -> {:noreply, refresh_after_review(socket, card, updated)}
        {:error, _reason} -> {:noreply, socket}
      end
    end
  end

  def handle_event("review_reject", _params, socket), do: {:noreply, socket}

  def handle_event("review_mark_done", _params, %{assigns: %{selected_card: %Card{status: :in_review} = card}} = socket) do
    case Cards.mark_done(card, current_actor(socket)) do
      {:ok, updated} -> {:noreply, refresh_card(socket, updated)}
      {:error, _changeset} -> {:noreply, socket}
    end
  end

  def handle_event("review_mark_done", _params, socket), do: {:noreply, socket}

  def handle_event("review_pull", _params, %{assigns: %{selected_card: %Card{status: :in_review} = card}} = socket) do
    actor = current_actor(socket)
    apply_owner_change(socket, Cards.add_owner(card, actor, actor))
  end

  def handle_event("review_pull", _params, socket), do: {:noreply, socket}

  # RLY-30 — the universal send-back control: any card with an earlier
  # main-lane stage can be bounced back with a note, not just review gates.
  def handle_event("send_back_open", _params, socket) do
    {:noreply, assign(socket, send_back_open: true, send_back_form: empty_send_back_form(), send_back_error: nil)}
  end

  def handle_event("send_back_cancel", _params, socket) do
    {:noreply, assign(socket, send_back_open: false, send_back_error: nil)}
  end

  def handle_event(
        "send_back",
        %{"send_back" => %{"note" => note} = params},
        %{assigns: %{selected_card: %Card{} = card}} = socket
      ) do
    if String.trim(note) == "" do
      {:noreply,
       assign(socket,
         send_back_form: to_form(params, as: :send_back),
         send_back_error: "Add a note — the AI needs to know what to change."
       )}
    else
      {:noreply, do_send_back(socket, card, resolve_stage(socket, params["to"]), note)}
    end
  end

  def handle_event("send_back", _params, socket), do: {:noreply, socket}

  defp do_send_back(socket, _card, nil, _note), do: assign(socket, send_back_error: "Pick an earlier stage.")

  defp do_send_back(socket, card, %Stage{} = target, note) do
    case Cards.send_back(card, target, note, current_actor(socket)) do
      {:ok, updated} -> refresh_after_review(socket, card, updated)
      {:error, _reason} -> assign(socket, send_back_error: "Pick an earlier stage.")
    end
  end

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
      %Card{id: ^card_id} -> {:noreply, insert_timeline_entry(socket, entry)}
      _other -> {:noreply, socket}
    end
  end

  def handle_info({:stages_changed, _board_id}, socket) do
    {:noreply, reload_board(socket)}
  end

  # RLY-10 — a board rename (this or another session): retitle live. The
  # broadcast board carries no preloaded stages, so merge just the name onto
  # the already-loaded @board (the open drawer reads @board.stages).
  def handle_info({:board_updated, %Board{} = board}, socket) do
    updated = %{socket.assigns.board | name: board.name, archived_at: board.archived_at}

    {:noreply,
     socket
     |> assign(:board, updated)
     |> assign(:page_title, board.name)
     |> assign(:read_only?, Board.archived?(updated))}
  end

  defp insert_timeline_entry(socket, %Schemas.Comment{} = comment) do
    stream_insert(socket, :conversation, comment)
  end

  defp insert_timeline_entry(socket, %Schemas.Activity{} = activity) do
    stream_insert(socket, :activity, activity, at: 0)
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

  # MMF 12c — a Review/Done sub-lane collapses to its 34px strip when empty
  # and not force-opened (mockup: laneCollapsed = isSub && laneCards.length === 0).
  defp sublane_collapsed?(%Stage{} = sub, stage_counts, force_open) do
    Map.fetch!(stage_counts, sub.id) == 0 and not MapSet.member?(force_open, sub.id)
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
  # card so the board card re-renders its colour/badge. Also recomputes
  # the needs-input panel's question from the fresh timeline (MMF 14).
  defp refresh_card(socket, %Card{} = card) do
    activity = Activity.list_activity(card)

    socket
    |> assign(:selected_card, card)
    |> assign(:status_form, status_form(card))
    |> assign(:question, latest_question(card, activity))
    |> assign(:answer_form, empty_answer_form())
    |> assign_review(card)
    |> stream(:conversation, Activity.list_conversation(card), reset: true)
    |> stream(:activity, activity, reset: true)
    |> stream_insert(stream_name(card.stage_id), card)
  end

  # Approve/reject moved the card: re-stream the source and target stage
  # columns (and counts) exactly like any move, then refresh the drawer to
  # the updated card — status form, review panel, and timeline included.
  defp refresh_after_review(socket, %Card{} = before, %Card{} = updated) do
    socket
    |> apply_move(before.stage_id, updated)
    |> refresh_card(updated)
  end

  # MMF 15 — the drawer's review-panel assigns. Recomputed on every drawer
  # refresh so the panel appears/disappears as the status changes and the
  # note sub-panel collapses after a transition.
  defp assign_review(socket, %Card{status: :in_review} = card) do
    assign(socket,
      review_gate: review_gate_info(socket, card),
      reject_open: false,
      reject_form: empty_reject_form(),
      reject_error: nil,
      send_back_open: false,
      send_back_form: empty_send_back_form(),
      send_back_error: nil
    )
  end

  defp assign_review(socket, _card) do
    assign(socket,
      review_gate: nil,
      reject_open: false,
      reject_form: empty_reject_form(),
      reject_error: nil,
      send_back_open: false,
      send_back_form: empty_send_back_form(),
      send_back_error: nil
    )
  end

  # Gate info for the review panel, or nil when the governing stage (the
  # card's own main-lane stage, or the sub-lane's parent) is not an
  # approval gate — mirroring Cards.approve/reject's :not_gated guard so
  # Approve/Request-changes only render where the transition can succeed.
  defp review_gate_info(socket, %Card{} = card) do
    stage = find_stage_by_id(socket, card.stage_id)
    gate = if stage.lane == :main, do: stage, else: find_stage_by_id(socket, stage.parent_id)

    if gate && gate.approval_gate do
      %{
        approve_label: approve_label(gate),
        reject_to_name: reject_to_name(socket, gate),
        targets: gate_reject_targets(socket, card),
        default_to: gate.reject_to_stage_id || gate.id
      }
    end
  end

  # Mirrors Cards.approve/2 routing: next main stage by position, or done
  # in place at the board's last main stage (mockup: "Approve → Deploy").
  defp approve_label(gate) do
    case Boards.next_main_stage(gate) do
      nil -> "Approve → Done"
      %Stage{name: name} -> "Approve → #{name}"
    end
  end

  # Mirrors Cards.reject/3 routing: the gate's configured target, or the
  # gate's own main lane when unset.
  defp reject_to_name(_socket, %Stage{reject_to_stage_id: nil} = gate), do: gate.name
  defp reject_to_name(socket, %Stage{reject_to_stage_id: target_id}), do: find_stage_by_id(socket, target_id).name

  defp empty_reject_form, do: to_form(%{"note" => ""}, as: :reject)

  defp empty_send_back_form, do: to_form(%{"to" => "", "note" => ""}, as: :send_back)

  # Universal send-back targets: main-lane stages strictly before the card's
  # current main stage, in position order. Only called (from the template)
  # while a card is selected, so no card is not a case to handle here.
  defp send_back_targets(board, %Card{} = card) do
    pos = current_main_position(board, card)

    board.stages
    |> Enum.filter(&(&1.lane == :main and &1.position < pos))
    |> Enum.sort_by(& &1.position)
    |> Enum.map(&%{id: &1.id, name: &1.name})
  end

  # Gate reject picker: main-lane stages at or before the current stage
  # (the gate's nil-target reject lands in the gate itself, so "at" is allowed).
  defp gate_reject_targets(socket, %Card{} = card) do
    board = socket.assigns.board
    pos = current_main_position(board, card)

    board.stages
    |> Enum.filter(&(&1.lane == :main and &1.position <= pos))
    |> Enum.sort_by(& &1.position)
    |> Enum.map(&%{id: &1.id, name: &1.name})
  end

  defp current_main_position(board, %Card{stage_id: stage_id}) do
    by_id = Map.new(board.stages, &{&1.id, &1})
    stage = Map.fetch!(by_id, stage_id)
    main = if stage.lane == :main, do: stage, else: Map.fetch!(by_id, stage.parent_id)
    main.position
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

  # MMF 11 / RLY-35 — soft enforcement, now sub-lane-aware. A move that lands
  # in a limited main stage OR any of its sub-lanes still succeeds; the acting
  # session gets a non-blocking flash when the governing main stage's total
  # (main + sub-lanes, from the freshly recomputed @stage_counts) is over
  # limit. A move whose source and target share the same governing main stage
  # (a reorder, or shuffling between a stage and its own sub-lanes) never
  # warns, and only this handler flashes — broadcast-applied moves stay silent.
  defp maybe_warn_over_wip(socket, %Stage{} = target, from_stage_id) do
    case governing_main_stage(socket, target) do
      %Stage{wip_limit: limit} = gate when is_integer(limit) ->
        used = wip_used(socket, gate)

        if governing_main_id(socket, from_stage_id) != gate.id and used > limit do
          put_flash(socket, :error, "#{gate.name} is over its WIP limit — #{used}/#{limit}")
        else
          socket
        end

      _ ->
        socket
    end
  end

  # The main-lane stage a WIP limit is charged against: the stage itself when
  # it's a main lane, else its parent. A move into any sub-lane counts here.
  defp governing_main_stage(_socket, %Stage{lane: :main} = stage), do: stage
  defp governing_main_stage(socket, %Stage{parent_id: parent_id}), do: find_stage_by_id(socket, parent_id)

  # The id of the governing main stage for an arbitrary stage id (source of a move).
  defp governing_main_id(socket, stage_id) do
    case find_stage_by_id(socket, stage_id) do
      %Stage{} = stage -> governing_main_stage(socket, stage).id
      _ -> nil
    end
  end

  # Effective WIP count for a main stage: its own cards plus every sub-lane's,
  # read from the freshly recomputed @stage_counts.
  defp wip_used(socket, %Stage{id: id}) do
    counts = socket.assigns.stage_counts

    socket.assigns.sublanes_by_parent
    |> Map.get(id, [])
    |> Enum.reduce(Map.fetch!(counts, id), fn sub, acc -> acc + Map.fetch!(counts, sub.id) end)
  end

  defp refresh_selected_after_move(socket, %Card{} = moved) do
    moved_id = moved.id

    case socket.assigns.selected_card do
      %Card{id: ^moved_id} ->
        socket
        |> assign(:selected_card, moved)
        |> assign(:selected_stage, find_stage_by_id(socket, moved.stage_id))
        |> assign_review(moved)
        |> stream(:conversation, Activity.list_conversation(moved), reset: true)
        |> stream(:activity, Activity.list_activity(moved), reset: true)

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
    board = Boards.get_board!(socket.assigns.current_scope.user, socket.assigns.board.slug)
    cards_by_stage = board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)

    socket =
      socket
      |> assign(:board, board)
      |> assign(:read_only?, Board.archived?(board))
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
        activity = Activity.list_activity(card)

        socket
        |> assign(:selected_card, card)
        |> assign(:selected_stage, find_stage_by_id(socket, card.stage_id))
        |> assign(:title_form, to_form(%{"title" => card.title}, as: :card))
        |> assign(:editing_title, false)
        |> assign(:editing_description, false)
        |> assign(:description_form, nil)
        |> assign(:status_form, status_form(card))
        |> assign(:comment_form, empty_comment_form())
        |> assign(:question, latest_question(card, activity))
        |> assign(:answer_form, empty_answer_form())
        |> assign_review(card)
        |> stream(:conversation, Activity.list_conversation(card), reset: true)
        |> stream(:activity, activity, reset: true)

      nil ->
        socket
        |> assign(
          selected_card: nil,
          selected_stage: nil,
          title_form: nil,
          editing_title: false,
          editing_description: false,
          description_form: nil,
          status_form: nil,
          comment_form: nil,
          question: nil,
          answer_form: nil,
          review_gate: nil,
          reject_open: false,
          reject_form: nil,
          reject_error: nil,
          send_back_open: false,
          send_back_form: nil,
          send_back_error: nil
        )
        |> stream(:conversation, [], reset: true)
        |> stream(:activity, [], reset: true)
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

  defp empty_answer_form, do: to_form(%{"body" => ""}, as: :answer)

  # The panel shows the newest :needs_input question. A human-blocked card
  # (status control — no question recorded) yields nil, and the panel
  # renders with just the composer (spec edge case).
  defp latest_question(%Card{status: :needs_input}, activity) do
    Enum.find_value(activity, fn
      %Schemas.Activity{type: :needs_input, meta: meta} -> meta["question"]
      _entry -> nil
    end)
  end

  defp latest_question(_card, _activity), do: nil

  defp conversation_dom_id(%Schemas.Comment{id: id}), do: "timeline-comment-#{id}"
  defp activity_dom_id(%Schemas.Activity{id: id}), do: "timeline-activity-#{id}"

  defp category_label(:unstarted), do: "Unstarted"
  defp category_label(:planning), do: "Planning"
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
  # catMeta dots: a hollow ring (unstarted), a quarter-filled violet conic
  # (planning — where AI planning lives), a half-filled blue conic
  # (in progress), and a solid green disc (complete).
  defp category_dot_style(:unstarted),
    do:
      "width:9px;height:9px;border-radius:50%;border:1.5px solid oklch(0.68 0.02 255);box-sizing:border-box;display:block;flex:0 0 auto;"

  defp category_dot_style(:planning),
    do:
      "width:9px;height:9px;border-radius:50%;background:conic-gradient(var(--color-secondary) 0 25%, oklch(0.86 0.03 250) 25% 100%);display:block;flex:0 0 auto;"

  defp category_dot_style(:in_progress),
    do:
      "width:9px;height:9px;border-radius:50%;background:conic-gradient(var(--color-primary) 0 50%, oklch(0.86 0.03 250) 50% 100%);display:block;flex:0 0 auto;"

  defp category_dot_style(:complete),
    do: "width:9px;height:9px;border-radius:50%;background:var(--color-success);display:block;flex:0 0 auto;"
end
