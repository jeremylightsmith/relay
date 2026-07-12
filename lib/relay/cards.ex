defmodule Relay.Cards do
  @moduledoc """
  The Cards context: cards on a board, per-board ref allocation
  (RLY-1, RLY-2, ...), and per-stage ordering.

  An "actor" is either the single Relay AI agent (`:agent`) or a user
  (`{:user, user_id}`) — the same concept later reused for comments
  (MMF 07) and API attribution (MMF 09).
  """

  use Boundary, deps: [Relay.Activity, Relay.Boards, Relay.Events, Relay.Repo, Schemas]

  import Ecto.Query

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Events
  alias Relay.Repo
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.CardOwner
  alias Schemas.CardRejection
  alias Schemas.Stage
  alias Schemas.SubTask
  alias Schemas.User

  # Approve/reject append the card to the bottom of the target stage;
  # move_card/4 clamps this into range.
  @append_index 1_000_000

  # Every Card column EXCEPT the heavy text bodies (:description, :spec, :plan).
  # list_cards/1,2 loads only these so a whole-board render (LiveView columns + the
  # API index) never drags multi-KB spec/plan/description text it doesn't show
  # (RLY-67). :rejection is an inline embeds_one column and rides along in the struct;
  # anything needing the omitted text must go through get_card_by_ref/2.
  @list_card_fields [
    :id,
    :title,
    :position,
    :tag,
    :ref_number,
    :status,
    :blocked_since,
    :archived_at,
    :branch,
    :pr_url,
    :ai_result,
    :board_id,
    :stage_id,
    :rejection,
    :inserted_at,
    :updated_at
  ]

  @doc """
  Creates a card in `stage` from user-supplied `attrs` (`:title`, optional
  `:tag`), attributed to `actor` (`:agent | {:user, user_id}`, defaults to
  `:agent` — the API identity; web callers pass the signed-in user),
  returning `{:ok, card}` or `{:error, changeset}`.

  The next per-board `ref_number` is allocated by locking the board row
  (`SELECT ... FOR UPDATE`) and bumping `Board.card_seq` inside the
  transaction, so refs are sequential and gap-free even under concurrent
  creates. The card is inserted at the top of the stage (RLY-1 item 5). A
  successful create logs a `:created` activity entry (MMF 07) attributed to
  `actor`.
  """
  def create_card(%Stage{} = stage, attrs, actor \\ :agent) do
    result =
      Repo.transaction(fn ->
        ref_number = allocate_ref_number(stage.board_id)

        case insert_card(stage, ref_number, attrs) do
          {:ok, card} ->
            {:ok, _entry} = Activity.log(card, %{type: :created, actor: actor})
            preload_owners(card)

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    broadcast_upserted(result)
  end

  @doc """
  Returns all of `board`'s non-archived cards, ordered by stage then
  `position` — the render order within each stage column. Archived cards
  (RLY-4) are excluded, so they drop out of every stage/category/WIP count
  for free.

  **Loads a trimmed projection (RLY-67):** `description`, `spec`, and `plan`
  come back `nil` — a whole-board view never renders them. Anything needing
  those heavy text bodies must fetch the full card via `get_card_by_ref/2`
  (the drawer already does). Every other column, the `owners: :user` and
  ordered `sub_tasks` preloads, and the `rejection` embed are populated.

  `opts`:
    * `:exclude_stage_ids` — a list of stage ids to drop from the result
      (the API index passes the board's top-level Done stage ids by default).
  """
  def list_cards(%Board{id: board_id}, opts \\ []) do
    exclude_stage_ids = Keyword.get(opts, :exclude_stage_ids, [])

    Card
    |> where([c], c.board_id == ^board_id and is_nil(c.archived_at))
    |> exclude_stages(exclude_stage_ids)
    |> order_by([c], asc: c.stage_id, asc: c.position, asc: c.id)
    |> select([c], struct(c, @list_card_fields))
    |> Repo.all()
    |> Repo.preload(card_preloads())
  end

  defp exclude_stages(query, []), do: query
  defp exclude_stages(query, ids), do: where(query, [c], c.stage_id not in ^ids)

  @doc """
  Returns the newest `limit` non-archived cards in `stage`, ordered
  `updated_at DESC, id DESC` — the terminal Done column's render window
  (RLY-53). `updated_at` is the recency proxy for "recently completed": a
  card's row is touched when it moves into a stage. Owners (`:user`) and
  position-ordered sub_tasks are preloaded exactly like `list_cards/1`, so the
  board columns can render the result directly.
  """
  def list_stage_cards(%Stage{id: stage_id}, limit) when is_integer(limit) and limit >= 0 do
    Card
    |> where([c], c.stage_id == ^stage_id and is_nil(c.archived_at))
    |> order_by([c], desc: c.updated_at, desc: c.id)
    |> limit(^limit)
    |> Repo.all()
    |> Repo.preload(card_preloads())
  end

  @doc """
  Archives `card` (RLY-4): a reversible soft-hide. Stamps `archived_at`
  (truncated UTC, like boards), attributes an `:archived` activity to
  `actor` (`:agent | {:user, user_id}`, defaults to `:agent`), and
  broadcasts `{:card_archived, card}` so open boards drop it from its
  column. Idempotent-friendly: archiving an already-archived card is a
  harmless re-stamp that logs nothing new (only the active→archived
  transition logs `:archived`). Returns `{:ok, card}` with owners
  preloaded.
  """
  def archive_card(%Card{} = card, actor \\ :agent) do
    was_active? = is_nil(card.archived_at)

    {:ok, archived} =
      card
      |> Ecto.Changeset.change(archived_at: DateTime.truncate(DateTime.utc_now(), :second))
      |> Repo.update()

    archived = preload_owners(archived)

    if was_active? do
      {:ok, _entry} = Activity.log(archived, %{type: :archived, actor: actor})
    end

    Events.broadcast(archived.board_id, {:card_archived, archived})
    {:ok, archived}
  end

  @doc """
  Restores an archived `card` (RLY-4): clears `archived_at`, attributes an
  `:unarchived` activity to `actor`, and broadcasts the existing
  `{:card_upserted, card}` so open boards re-insert it through the current
  upsert handler (no dedicated restore event). Only the archived→active
  transition logs and broadcasts; restoring an already-active card is a
  no-op. Returns `{:ok, card}` with owners preloaded.
  """
  def unarchive_card(%Card{} = card, actor \\ :agent) do
    was_archived? = not is_nil(card.archived_at)

    {:ok, restored} =
      card
      |> Ecto.Changeset.change(archived_at: nil)
      |> Repo.update()

    restored = preload_owners(restored)

    if was_archived? do
      {:ok, _entry} = Activity.log(restored, %{type: :unarchived, actor: actor})
      Events.broadcast(restored.board_id, {:card_upserted, restored})
    end

    {:ok, restored}
  end

  @doc """
  The board's archived cards, most-recently-archived first, with `:stage`
  and `owners` preloaded — the "Archived cards" modal's list.
  """
  def list_archived_cards(%Board{id: board_id}) do
    Repo.all(
      from c in Card,
        where: c.board_id == ^board_id and not is_nil(c.archived_at),
        order_by: [desc: c.archived_at, desc: c.id],
        preload: [:stage, owners: :user]
    )
  end

  @doc "How many of the board's cards are archived (the header button's badge)."
  def count_archived_cards(%Board{id: board_id}) do
    Repo.aggregate(from(c in Card, where: c.board_id == ^board_id and not is_nil(c.archived_at)), :count)
  end

  @doc "How many non-archived cards the board has (the boards-home tile count)."
  def count_cards(%Board{id: board_id}) do
    Repo.aggregate(from(c in Card, where: c.board_id == ^board_id and is_nil(c.archived_at)), :count)
  end

  @doc """
  The human-facing card ref: the board's key plus the card's per-board
  ref number, e.g. `"RLY-12"`.

  Takes the board explicitly (a refinement of the spec's sketched
  `Card.ref/1`) so callers that already hold the board don't need
  `card.board` preloaded.
  """
  def ref(%Board{key: key}, %Card{ref_number: ref_number}), do: "#{key}-#{ref_number}"

  @doc """
  Updates a card's user/agent-editable attributes (`:title`, `:description`,
  `:tag`, `:branch`, `:plan`), returning `{:ok, card}` or
  `{:error, changeset}`. The programmatic fields (`board_id`, `stage_id`,
  `position`, `ref_number`) are never cast and cannot be changed here.
  """
  def update_card(%Card{} = card, attrs) do
    card
    |> Card.changeset(attrs)
    |> Repo.update()
    |> preload_owners_result()
    |> broadcast_upserted()
  end

  @doc """
  Replaces the card's whole sub-task checklist with `attrs_list` (a list of
  `%{"title" => ..., "done" => bool?}` maps) inside a transaction: deletes the
  card's existing sub_tasks and inserts the new list with `position` 0..n. Used by
  the Plan stage to write the checklist. Returns `{:ok, card}` (sub_tasks preloaded
  in position order) or `{:error, changeset}`; broadcasts `{:card_upserted, card}`.
  """
  def set_sub_tasks(%Card{} = card, attrs_list) when is_list(attrs_list) do
    result =
      Repo.transaction(fn ->
        Repo.delete_all(from st in SubTask, where: st.card_id == ^card.id)

        attrs_list
        |> Enum.with_index()
        |> Enum.each(fn {attrs, position} -> insert_sub_task!(card, attrs, position) end)

        reload_with_owners(card)
      end)

    broadcast_upserted(result)
  end

  @doc """
  Sets one sub-task's `done` flag, scoped to `card`. Used by the Code stage (mark an
  item complete) and the drawer toggle. Returns `{:ok, card}` (reloaded, preloaded)
  or `{:error, :not_found}` when the id isn't one of the card's sub_tasks; broadcasts
  `{:card_upserted, card}`.
  """
  def set_sub_task_done(%Card{} = card, sub_task_id, done) when is_integer(sub_task_id) and is_boolean(done) do
    case Repo.get_by(SubTask, id: sub_task_id, card_id: card.id) do
      %SubTask{} = sub_task ->
        {:ok, _updated} = sub_task |> SubTask.changeset(%{done: done}) |> Repo.update()
        broadcast_upserted({:ok, reload_with_owners(card)})

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Sets the card's `ai_result` blob (a string-keyed map) via `update_card/2` (which
  broadcasts). Plan/Code write the summary + changes + screens.
  """
  def update_ai_result(%Card{} = card, ai_result) when is_map(ai_result) do
    update_card(card, %{ai_result: ai_result})
  end

  @doc """
  Pure helper: `%{done: d, total: t}` from a map with a **loaded** `sub_tasks` list
  (a Card struct or a plain map). Used by both the JSON and the drawer.
  """
  def sub_task_progress(%{sub_tasks: sub_tasks}) when is_list(sub_tasks) do
    %{done: Enum.count(sub_tasks, & &1.done), total: length(sub_tasks)}
  end

  @doc """
  Sets the card's baton status (`:ready | :working | :needs_input |
  :in_review`) from `attrs`, attributed to `actor` (`:agent |
  {:user, user_id}`, defaults to `:agent`), returning `{:ok, card}`
  (owners preloaded) or `{:error, changeset}`. Status only ever changes
  through this explicit call — never as a side effect of moving a card.
  Logs a `:status_changed` activity entry (MMF 07) only when the status
  value actually changes (a same-status re-set logs nothing). Entering
  `:needs_input` stamps `blocked_since` and leaving it clears it (MMF 14,
  managed in `Schemas.Card.status_changeset/2`).
  """
  def set_status(%Card{} = card, attrs, actor \\ :agent) do
    from_status = card.status

    card
    |> Card.status_changeset(attrs)
    |> Repo.update()
    |> preload_owners_result()
    |> log_status_changed(from_status, actor)
    |> broadcast_upserted()
  end

  @doc """
  Replaces the card's whole owner list with `actors`
  (`:agent | {:user, user_id}`) atomically, attributed to `actor`
  (`:agent | {:user, user_id}`, defaults to `:agent`), returning
  `{:ok, card}` with owners preloaded or `{:error, changeset}` (nothing
  changes on error). Logs an `:owners_changed` activity entry (MMF 07)
  with the new owner labels.
  """
  def set_owners(%Card{} = card, actors, actor \\ :agent) when is_list(actors) do
    result =
      Repo.transaction(fn ->
        Repo.delete_all(from o in CardOwner, where: o.card_id == ^card.id)
        Enum.each(actors, &insert_owner_or_rollback(card, &1))
        log_owners_changed(card, actor, %{"action" => "set", "owners" => Enum.map(actors, &owner_label/1)})
        reload_with_owners(card)
      end)

    broadcast_upserted(result)
  end

  @doc """
  Assigns Relay AI as the card's sole owner (RLY-47 hand-off), attributed to
  `actor`. A thin wrapper over `set_owners/3`; clears any human owners
  (exclusivity, rule 2). Status is untouched. Returns `{:ok, card}` or
  `{:error, changeset}`.
  """
  def assign_ai(%Card{} = card, actor \\ :agent), do: set_owners(card, [:agent], actor)

  @doc """
  Flips ownership to the human `{:user, id}` (RLY-47 "Take over"), attributed to
  that user. A thin wrapper over `set_owners/3`; drops the AI (exclusivity, rule
  2). Status is untouched — provenance changes, the baton's substate does not.
  Returns `{:ok, card}` or `{:error, changeset}`.
  """
  def take_over(%Card{} = card, {:user, _id} = actor), do: set_owners(card, [actor], actor)

  @doc """
  Adds one owner actor to the card, attributed to `actor`
  (`:agent | {:user, user_id}`, defaults to `:agent`), returning
  `{:ok, card}` with owners preloaded. Enforces the RLY-47 AI-exclusivity
  invariant: Relay AI and humans never co-own a card. Assigning `:agent`
  clears every human owner (rule 2); adding a `{:user, id}` owner to an
  AI-owned card removes the agent first (take-over). Adding an actor that is
  already an owner is an ok no-op that logs nothing; otherwise logs an
  `:owners_changed` activity entry.
  """
  def add_owner(card, owner_actor, actor \\ :agent)

  def add_owner(%Card{} = card, :agent, actor) do
    already_owner? = Repo.exists?(owner_query(card, :agent))

    result =
      Repo.transaction(fn ->
        Repo.delete_all(from o in CardOwner, where: o.card_id == ^card.id and o.actor_type == ^:user)
        {:ok, _owner} = insert_owner(card, :agent)

        if not already_owner? do
          log_owners_changed(card, actor, %{"action" => "added", "owner" => owner_label(:agent)})
        end

        reload_with_owners(card)
      end)

    broadcast_upserted(result)
  end

  def add_owner(%Card{} = card, {:user, _user_id} = owner_actor, actor) do
    already_owner? = Repo.exists?(owner_query(card, owner_actor))

    result =
      Repo.transaction(fn ->
        Repo.delete_all(from o in CardOwner, where: o.card_id == ^card.id and o.actor_type == ^:agent)
        insert_owner_or_rollback(card, owner_actor)

        if not already_owner? do
          log_owners_changed(card, actor, %{"action" => "added", "owner" => owner_label(owner_actor)})
        end

        reload_with_owners(card)
      end)

    broadcast_upserted(result)
  end

  @doc """
  Removes one owner actor from the card, attributed to `actor`
  (`:agent | {:user, user_id}`, defaults to `:agent`), returning
  `{:ok, card}` with owners preloaded. Removing an actor that is not an
  owner is an ok no-op that logs nothing; otherwise logs an
  `:owners_changed` activity entry (MMF 07) with the owner label.
  """
  def remove_owner(%Card{} = card, owner_actor, actor \\ :agent) do
    {deleted, _} = Repo.delete_all(owner_query(card, owner_actor))

    if deleted > 0 do
      log_owners_changed(card, actor, %{"action" => "removed", "owner" => owner_label(owner_actor)})
    end

    broadcast_upserted({:ok, reload_with_owners(card)})
  end

  @doc """
  Derives who holds the baton from the (preloaded) owner list: `:ai` when
  the agent is among the owners, `:human` when only humans own it, `nil`
  when unowned. Never stored — always derived. Accepts any map with a
  loaded `owners` list so components can use it on plain maps too.
  """
  def active_owner_type(%{owners: owners}) when is_list(owners) do
    cond do
      Enum.any?(owners, &(&1.actor_type == :agent)) -> :ai
      owners != [] -> :human
      true -> nil
    end
  end

  @doc """
  Derived Done: a `:ready` card parked at the board's **terminal** stage (the last top-level
  stage in `stages`, `Relay.Boards.terminal_stage/1`). A `:ready` card in a *mid-board* Done
  sub-lane is NOT done — it is merely parked. Pure; takes the board's in-memory stage list.
  """
  def done?(%{status: :ready, stage_id: stage_id}, stages) do
    case Boards.terminal_stage(stages) do
      %Stage{id: ^stage_id} -> true
      _ -> false
    end
  end

  def done?(_card, _stages), do: false

  @doc """
  Derived "ready awaiting a human": a `:ready` card whose **puller** (the stage that works it
  next) exists and is not an AI-enabled work/planning stage. A card parked in an AI work stage
  is ambient (its own agent pulls it); parked before a human stage it is on a human; parked at
  the terminal stage the puller is `nil`, so it is Done, not awaiting-human. Pure.
  """
  def ready_awaiting_human?(%{status: :ready} = card, stages) do
    case worker_stage(card, stages) do
      %Stage{type: type, ai_enabled: true} when type in [:work, :planning] -> false
      %Stage{} -> true
      nil -> false
    end
  end

  def ready_awaiting_human?(_card, _stages), do: false

  @doc """
  The two-bucket "needs-you" fact: `:needs_input`/`:in_review` always count, plus
  ready-awaiting-human. NOTE this is deliberately broader than the board's amber accent (which
  is `status in [:needs_input, :in_review]` only) — a ready-awaiting-human card counts in
  rollups but is NOT painted amber (RLY-48 §2.3). Pure.
  """
  def needs_you?(%{status: status} = card, stages) do
    status in [:needs_input, :in_review] or ready_awaiting_human?(card, stages)
  end

  # The stage that pulls a parked card next: its own stage when that is a work/planning stage
  # (its worker starts it in place), else the next main stage (nil at the terminal stage).
  defp worker_stage(%{stage_id: stage_id}, stages) do
    case Enum.find(stages, &(&1.id == stage_id)) do
      %Stage{type: type} = current when type in [:work, :planning] -> current
      %Stage{} = current -> next_main_stage(stages, current)
      nil -> nil
    end
  end

  # The next top-level stage after `current`'s governing main stage (its own id when main-lane,
  # else its sub-lane parent), by position. nil when `current`'s main stage is the terminal one.
  defp next_main_stage(stages, %Stage{} = current) do
    governing_id = current.parent_id || current.id

    stages
    |> Enum.filter(&is_nil(&1.parent_id))
    |> Enum.sort_by(& &1.position)
    |> Enum.drop_while(&(&1.id != governing_id))
    |> Enum.drop(1)
    |> List.first()
  end

  @doc """
  The board's three-way needs-you rollup: `%{needs_input: n, in_review: n, awaiting_human: n}`
  (total needs-you = their sum). Loads the board's active cards + stages once and folds the
  derivations. Used by the board API payload (§6.1) and the boards-home tiles (§6.3).
  """
  def needs_you_rollup(%Board{} = board) do
    stages = Boards.list_stages(board)
    cards = list_cards(board)

    Enum.reduce(cards, %{needs_input: 0, in_review: 0, awaiting_human: 0}, fn card, acc ->
      cond do
        card.status == :needs_input -> Map.update!(acc, :needs_input, &(&1 + 1))
        card.status == :in_review -> Map.update!(acc, :in_review, &(&1 + 1))
        ready_awaiting_human?(card, stages) -> Map.update!(acc, :awaiting_human, &(&1 + 1))
        true -> acc
      end
    end)
  end

  @doc """
  A `card_id => latest :needs_input question` map for the board's `:needs_input` cards, for the
  board's collapsed-card question previews (RLY-48 §3). One indexed query; empty when no card is
  blocked. A blocked card with no recorded question (e.g. a manual status flip) is absent.
  """
  def needs_input_questions(%Board{id: board_id}) do
    from(a in Schemas.Activity,
      join: c in Card,
      on: c.id == a.card_id,
      where: c.board_id == ^board_id and c.status == :needs_input and a.type == :needs_input,
      order_by: [asc: a.card_id, desc: a.inserted_at, desc: a.id],
      select: {a.card_id, a.meta}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {card_id, meta}, acc ->
      Map.put_new(acc, card_id, meta["question"])
    end)
  end

  # Light card columns for the optimistic drawer's first paint (RLY-68):
  # every Card field except the multi-KB heavy text
  # (description/spec/plan/ai_result). Derived from @list_card_fields (RLY-67)
  # minus :ai_result, so there is one source of truth for the board's light
  # projection and this even-lighter drawer projection never drifts from it.
  @light_card_fields @list_card_fields -- [:ai_result]

  @doc """
  Like `get_card_by_ref/2`, but selects only the card's light columns
  (everything except the heavy `description`/`spec`/`plan`/`ai_result`
  text), still preloading `owners: :user` and position-ordered
  `sub_tasks`. The heavy string fields come back `nil`. Powers the
  optimistic card drawer's instant first paint (RLY-68); the drawer's
  async fill re-fetches the full card via `get_card_by_ref/2`.
  Board-scoped exactly like `get_card_by_ref/2`, so a ref can never
  resolve to another board's card.
  """
  def get_card_light_by_ref(%Board{} = board, ref) when is_binary(ref) do
    case parse_ref_number(board, ref) do
      {:ok, ref_number} ->
        Card
        |> where([c], c.board_id == ^board.id and c.ref_number == ^ref_number)
        |> select([c], struct(c, @light_card_fields))
        |> Repo.one()
        |> preload_owners()

      :error ->
        nil
    end
  end

  @doc """
  Fetches the card a human-facing ref (e.g. `"RLY-12"`) points at on
  `board`, or `nil` when the ref does not parse against the board's key
  or no such card exists on that board. Scoping by `board_id` means a
  ref can never resolve to another board's card — this is the card
  drawer's authorization check.
  """
  def get_card_by_ref(%Board{} = board, ref) when is_binary(ref) do
    case parse_ref_number(board, ref) do
      {:ok, ref_number} ->
        Card
        |> Repo.get_by(board_id: board.id, ref_number: ref_number)
        |> preload_owners()

      :error ->
        nil
    end
  end

  @doc """
  Moves `card` into `target_stage` at the 0-based `index` among the
  stage's cards (excluding the moved card itself), attributed to `actor`
  (`:agent | {:user, user_id}`, defaults to `:agent`), returning
  `{:ok, card}` or `{:error, changeset}`.

  The whole target stage is re-indexed inside a transaction so
  `position` stays contiguous (1..n) and deterministic; `index` is
  clamped into range. The target stage must belong to the card's board —
  callers resolve both on the current board, and a cross-board call
  raises `FunctionClauseError`. A cross-stage move logs a `:moved`
  activity entry (MMF 07) attributed to `actor`.
  """
  def move_card(%Card{board_id: board_id} = card, %Stage{board_id: board_id} = target_stage, index, actor \\ :agent)
      when is_integer(index) do
    previous_stage_id = card.stage_id

    result =
      Repo.transaction(fn ->
        moved = preload_owners(place_at(card, target_stage, index))

        moved =
          if moved.stage_id == previous_stage_id do
            moved
          else
            emit_stage_changed(moved, previous_stage_id, target_stage, actor)

            moved
            |> snap_status(target_stage, actor)
            |> maybe_claim(target_stage, actor)
          end

        maybe_clear_rejection(moved)
      end)

    case result do
      {:ok, moved} ->
        Events.broadcast(moved.board_id, {:card_moved, moved, previous_stage_id})
        {:ok, moved}

      {:error, _changeset} = error ->
        error
    end
  end

  # ADR 0003 snap: keep the card's status if it's valid for the destination type, else set the
  # type's default. Only ever called on a cross-stage move.
  defp snap_status(%Card{} = card, %Stage{} = target, actor) do
    if Stage.valid_status?(card.status, target.type) do
      card
    else
      {:ok, updated} = set_status(card, %{status: Stage.default_status(target.type)}, actor)
      updated
    end
  end

  # RLY-47 — the design's five stage "types" are DERIVED from the schema; there is no
  # stage `type`-per-design column. A "Work/Planning" stage is a main-lane stage whose
  # behavior type is :work or :planning; review gates and Queue/Done never claim (rule 5).
  defp work_stage?(%Stage{parent_id: nil, type: type}) when type in [:work, :planning], do: true
  defp work_stage?(_), do: false

  # An AI-enabled work stage: a Work/Planning stage with ai_enabled true.
  defp ai_stage?(%Stage{ai_enabled: true} = stage), do: work_stage?(stage)
  defp ai_stage?(_), do: false

  # The claim rule (RLY-47): an UNOWNED card claims an owner when it ENTERS a stage.
  # An already-owned card keeps its owners through every move — this single guard
  # delivers rules 5 (reviews never transfer) and 6 (no hand-back): ownership is never
  # stripped and never handed back.
  defp maybe_claim(%Card{owners: owners} = card, _target, _actor) when owners != [], do: card

  defp maybe_claim(%Card{} = card, %Stage{} = target, actor) do
    cond do
      # rule 3 (corrected — the MOVER decides): whoever moves an unowned card into a
      # work/planning stage takes it on. A human dragging a card into ANY work stage —
      # AI-enabled or not — becomes its owner, which locks the agent out (the runner
      # skips human-owned cards, rule 4).
      work_stage?(target) and match?({:user, _}, actor) -> put_owners(card, [actor], actor)
      # rule 1: a non-human mover (the runner/API acting as :agent) dropping an unowned
      # card into an AI-enabled stage delegates it to Relay AI.
      ai_stage?(target) -> put_owners(card, [:agent], actor)
      # Queue, Done, Review, or an agent moving into a human-only stage: leave unowned.
      true -> card
    end
  end

  # Replaces the owner list from INSIDE an already-open transaction (the claim runs inside
  # move_card/4's txn). Mirrors set_owners/3's delete-all + insert but does NOT open its own
  # transaction or broadcast — move_card's {:card_moved} already re-renders every session
  # from the freshly-owned card.
  defp put_owners(%Card{} = card, actors, actor) do
    Repo.delete_all(from o in CardOwner, where: o.card_id == ^card.id)
    Enum.each(actors, &insert_owner_or_rollback(card, &1))
    log_owners_changed(card, actor, %{"action" => "set", "owners" => Enum.map(actors, &owner_label/1)})
    reload_with_owners(card)
  end

  @doc """
  Re-snaps every card currently in `stage` to a status valid for the stage's `type` (ADR 0003):
  a card whose status is already valid is left alone; otherwise it takes the type's default via
  `set_status/2` (broadcasting the change). Called after a stage's type changes in settings.
  """
  def snap_cards_in(%Stage{} = stage) do
    Card
    |> where([c], c.stage_id == ^stage.id and is_nil(c.archived_at))
    |> Repo.all()
    |> preload_owners()
    |> Enum.each(fn card ->
      if !Stage.valid_status?(card.status, stage.type) do
        {:ok, _} = set_status(card, %{status: Stage.default_status(stage.type)}, :agent)
      end
    end)
  end

  @doc """
  Approves the card past its review-position stage (ADR 0003). Allowed when the card's
  current stage is `:review`-type; otherwise returns `{:error, :not_in_review}`. Moves
  the card to the bottom of the next main stage by position (sub-lane children are never
  "next"; from a sub-lane, next = the first main stage after the parent), arriving with
  the destination type's default status via the `move_card/4` snap. At the board's last
  main stage there is no move — the card's status becomes `:done` in place. Logs an
  `:approved` activity entry (from/to stage display names in meta) attributed to `actor`,
  and reuses `move_card`/`set_status`, so the usual
  `{:card_moved}`/`{:card_upserted}`/`{:timeline_appended}` events fire. Reused verbatim
  by the API (MMF 09) and the drawer (MMF 15).
  """
  def approve(%Card{} = card, actor \\ :agent) do
    stage = current_stage(card)

    if stage.type == :review do
      case Boards.next_main_stage(current_main_stage(card)) do
        nil -> approve_in_place(card, stage, actor)
        %Stage{} = target -> route(card, stage, target, :approved, nil, actor)
      end
    else
      {:error, :not_in_review}
    end
  end

  @doc """
  Rejects the card from its review-type stage back to a **derived** destination — the reviewer
  never picks one. A review **sub-lane** returns to its own parent main stage; a **top-level**
  review stage uses its configured `reject_to_stage_id`, else the previous main stage. Moves the
  card to the destination (arrival status via `move_card/4`'s snap), posts `note` as a comment,
  logs a `:rejected` entry, and sets the single open `rejection` embed. Returns `{:ok, card}` or
  `{:error, :not_in_review | :missing_note | :invalid_target | changeset}`.
  """
  def reject(%Card{} = card, note, actor \\ :agent) when is_binary(note) do
    stage = current_stage(card)

    cond do
      stage.type != :review -> {:error, :not_in_review}
      String.trim(note) == "" -> {:error, :missing_note}
      true -> do_reject(card, stage, note, actor)
    end
  end

  defp do_reject(card, stage, note, actor) do
    from_stage = current_main_stage(card)

    case reject_destination(stage, from_stage) do
      nil -> {:error, :invalid_target}
      %Stage{} = target -> move_and_reject(card, from_stage, target, note, actor)
    end
  end

  defp move_and_reject(card, from_stage, target, note, actor) do
    with {:ok, moved} <- move_card(card, target, @append_index, actor),
         :ok <- attach_note(moved, note, actor, :changes_requested) do
      log_gate(moved, :rejected, actor, from_stage, target, note)
      {:ok, put_rejection(moved, from_stage, target, note, actor)}
    end
  end

  @doc """
  The stage a reject from this card would land on, or `nil` when the card is not in a review-type
  stage or no destination exists (a first-column top-level review with no `reject_to`). Used by the
  drawer to *show* the destination without moving the card.
  """
  def reject_target(%Card{} = card) do
    stage = current_stage(card)
    if stage.type == :review, do: reject_destination(stage, current_main_stage(card))
  end

  # Sub-lane review → its own parent main stage (== the card's current_main_stage).
  defp reject_destination(%Stage{parent_id: parent_id}, from_stage) when not is_nil(parent_id), do: from_stage

  # Top-level review → configured reject_to, else the previous main stage.
  defp reject_destination(%Stage{parent_id: nil, reject_to_stage_id: nil} = stage, _from),
    do: Boards.previous_main_stage(stage)

  defp reject_destination(%Stage{parent_id: nil, reject_to_stage_id: target_id}, _from), do: Repo.get(Stage, target_id)

  @doc """
  Marks the card `:ready` in place (the drawer's "Mark done") and clears any open rejection —
  a card parked at the terminal stage then derives as Done. Returns `{:ok, card}` or
  `{:error, changeset}`.
  """
  def mark_done(%Card{} = card, actor \\ :agent) do
    case set_status(card, %{status: :ready}, actor) do
      {:ok, updated} -> {:ok, clear_rejection(updated)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Blocks the card on a human (MMF 14): sets status `:needs_input` — which
  stamps `blocked_since` (see `Schemas.Card.status_changeset/2`) — posts
  the question(s) as a comment from `actor`, and logs a `:needs_input` activity
  entry with the question in `meta` (the durable record the drawer's
  question panel reads). The MMF 09 `POST /api/cards/:ref/needs-input`
  endpoint routes here. Reuses `set_status`/`Relay.Activity`, so the usual
  `{:card_upserted}` / `{:timeline_appended}` events fire (MMF 18).

  Accepts either a plain string `question` (unchanged, single-question form) or (RLY-71) a
  **list** of question maps (each `%{"prompt" => ..., "options" => [...], "allow_text" => bool}`).
  For the list form, each item is normalized (defaults `options => []`, `allow_text => true`;
  unknown keys dropped), stored under `meta["questions"]` for the drawer stepper, and mirrored as
  a flattened, human-readable rendering into `meta["question"]` and the `:question` comment body
  so the board preview, the panel fallback, and the timeline all keep working unchanged.
  """
  def request_input(card, question_or_questions, actor \\ :agent)

  def request_input(%Card{} = card, question, actor) when is_binary(question) do
    with {:ok, updated} <- set_status(card, %{status: :needs_input}, actor),
         {:ok, _comment} <-
           Activity.add_comment(updated, %{actor: actor, body: question, kind: :question}),
         {:ok, _entry} <-
           Activity.log(updated, %{type: :needs_input, actor: actor, meta: %{"question" => question}}) do
      {:ok, updated}
    end
  end

  def request_input(%Card{} = card, questions, actor) when is_list(questions) do
    normalized = Enum.map(questions, &normalize_question/1)
    flattened = flatten_questions(normalized)

    with {:ok, updated} <- set_status(card, %{status: :needs_input}, actor),
         {:ok, _comment} <-
           Activity.add_comment(updated, %{actor: actor, body: flattened, kind: :question}),
         {:ok, _entry} <-
           Activity.log(updated, %{
             type: :needs_input,
             actor: actor,
             meta: %{"question" => flattened, "questions" => normalized}
           }) do
      {:ok, updated}
    end
  end

  # Coerce an incoming question map to the canonical string-keyed shape, filling defaults and
  # dropping any keys the stepper doesn't understand.
  defp normalize_question(question) when is_map(question) do
    %{
      "prompt" => Map.get(question, "prompt"),
      "options" => Map.get(question, "options") || [],
      "allow_text" => Map.get(question, "allow_text", true)
    }
  end

  # Numbered, human-readable rendering of the normalized questions — the comment body and the
  # back-compat meta["question"] value. Options are lettered a) b) c)…
  defp flatten_questions(normalized) do
    normalized
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {question, number} -> flatten_question(question, number) end)
  end

  defp flatten_question(%{"prompt" => prompt, "options" => []}, number), do: "#{number}. #{prompt}"

  defp flatten_question(%{"prompt" => prompt, "options" => options}, number) do
    lines = options |> Enum.with_index() |> Enum.map_join("\n", &flatten_option/1)
    "#{number}. #{prompt}\n" <> lines
  end

  defp flatten_option({option, index}), do: "   #{<<?a + index>>}) #{option}"

  @doc """
  Answers a blocked card's question (MMF 14): posts `answer` as a comment
  from `actor`, flips status to `:working` when the card's stage is meant
  for the AI (the agent resumes) or `:ready` otherwise — clearing
  `blocked_since` — and logs an `:input_answered` activity entry. The
  answer reaches the agent through the existing `GET /api/cards/:ref`
  timeline; no new endpoint. The comment posts first, so a blank answer
  fails before any status change. Reuses `set_status`/`Relay.Activity`,
  so the usual events fire (MMF 18).
  """
  def answer_input(%Card{} = card, answer, actor \\ :agent) when is_binary(answer) do
    with {:ok, _comment} <- Activity.add_comment(card, %{actor: actor, body: answer}),
         {:ok, updated} <- set_status(card, %{status: resume_status(card)}, actor),
         {:ok, _entry} <- Activity.log(updated, %{type: :input_answered, actor: actor}) do
      {:ok, updated}
    end
  end

  # Where an answered card resumes: the stage type's default status decides
  # (same rule as approve/reject arrivals).
  defp resume_status(%Card{stage_id: stage_id}) do
    Stage.default_status(Repo.get!(Stage, stage_id).type)
  end

  defp parse_ref_number(%Board{key: key}, ref) do
    prefix = key <> "-"

    with true <- String.starts_with?(ref, prefix),
         {ref_number, ""} <- Integer.parse(String.replace_prefix(ref, prefix, "")),
         true <- ref_number > 0 do
      {:ok, ref_number}
    else
      _ -> :error
    end
  end

  # A card is "in review position" iff its current stage is review-type (main or sub-lane).
  defp current_stage(%Card{stage_id: stage_id}), do: Repo.get!(Stage, stage_id)

  # The main-lane stage governing the card: its own stage when main-lane, else
  # its sub-lane's parent. Send-back targets are compared against this stage's
  # position.
  defp current_main_stage(%Card{stage_id: stage_id}) do
    stage = Repo.get!(Stage, stage_id)
    if is_nil(stage.parent_id), do: stage, else: Repo.get!(Stage, stage.parent_id)
  end

  # Sets the card's single open rejection embed, replacing any existing one
  # (on_replace: :delete), then broadcasts the upsert so open drawers show the
  # banner live (MMF 18).
  defp put_rejection(%Card{} = card, %Stage{} = from, %Stage{} = to, note, actor) do
    rejection = %CardRejection{
      note: note,
      from_stage_id: from.id,
      from_stage_name: Boards.stage_display_name(from),
      to_stage_id: to.id,
      to_stage_name: Boards.stage_display_name(to),
      rejected_by: actor_display_name(actor),
      rejected_at: DateTime.truncate(DateTime.utc_now(), :second)
    }

    {:ok, updated} =
      card
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_embed(:rejection, rejection)
      |> Repo.update()

    updated = preload_owners(updated)
    Events.broadcast(updated.board_id, {:card_upserted, updated})
    updated
  end

  # Clears an open rejection (approve / mark-done acceptance), broadcasting the
  # upsert so the drawer banner disappears live. A clean card is a no-op.
  defp clear_rejection(%Card{rejection: nil} = card), do: card

  defp clear_rejection(%Card{} = card) do
    {:ok, cleared} =
      card
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_embed(:rejection, nil)
      |> Repo.update()

    cleared = preload_owners(cleared)
    Events.broadcast(cleared.board_id, {:card_upserted, cleared})
    cleared
  end

  # Inside move_card's transaction: an open rejection clears when the card's new
  # main-lane stage is positioned at/after the stage it was rejected from — the
  # redo has climbed back to the checkpoint it fell from. A deleted from-stage
  # (nil) also clears. No broadcast here: move_card's {:card_moved} already
  # drives every session's re-render from the DB.
  defp maybe_clear_rejection(%Card{rejection: nil} = card), do: card

  defp maybe_clear_rejection(%Card{rejection: %CardRejection{from_stage_id: from_id}} = card) do
    dest = current_main_stage(card)
    from = Repo.get(Stage, from_id)

    if is_nil(from) or dest.position >= from.position do
      card
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_embed(:rejection, nil)
      |> Repo.update!()
      |> preload_owners()
    else
      card
    end
  end

  # The rejecter's display name snapshotted into the rejection banner.
  defp actor_display_name(:agent), do: "Relay AI"

  defp actor_display_name({:user, user_id}) do
    user = Repo.get!(User, user_id)
    user.name || user.email
  end

  # Shared approve/reject transition: move to the bottom of `target` (the snap in
  # move_card/4 sets the arrival status), attach the note (rejects only), then log the
  # :approved/:rejected entry.
  defp route(%Card{} = card, from_stage, %Stage{} = target, type, note, actor) do
    with {:ok, moved} <- move_card(card, target, @append_index, actor),
         :ok <- attach_note(moved, note, actor) do
      log_gate(moved, type, actor, from_stage, target, note)
      {:ok, clear_rejection(moved)}
    end
  end

  # Approve at the board's last main stage: :ready in place, no move (derives Done).
  defp approve_in_place(%Card{} = card, from_stage, actor) do
    case set_status(card, %{status: :ready}, actor) do
      {:ok, updated} ->
        log_gate(updated, :approved, actor, from_stage, from_stage, nil)
        {:ok, clear_rejection(updated)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp attach_note(card, note, actor, kind \\ :comment)
  defp attach_note(_card, nil, _actor, _kind), do: :ok

  defp attach_note(%Card{} = card, note, actor, kind) do
    case Activity.add_comment(card, %{actor: actor, body: note, kind: kind}) do
      {:ok, _comment} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp log_gate(%Card{} = card, type, actor, from_stage, to_stage, note) do
    meta = %{
      "from_stage" => Boards.stage_display_name(from_stage),
      "to_stage" => Boards.stage_display_name(to_stage)
    }

    meta = if note, do: Map.put(meta, "note", note), else: meta

    {:ok, _entry} = Activity.log(card, %{type: type, actor: actor, meta: meta})
  end

  # Re-indexes the target stage: its other cards keep their relative
  # order, `card` is inserted at the clamped index, and positions are
  # rewritten 1..n.
  defp place_at(%Card{} = card, %Stage{} = target_stage, index) do
    others =
      Repo.all(
        from c in Card,
          where: c.stage_id == ^target_stage.id and c.id != ^card.id,
          order_by: [asc: c.position, asc: c.id]
      )

    index = index |> max(0) |> min(length(others))

    others
    |> List.insert_at(index, card)
    |> Enum.with_index(1)
    |> Enum.map(&reposition(&1, target_stage.id))
    |> Enum.find(&(&1.id == card.id))
  end

  # `card` may be a caller-held reference that's gone stale relative to the
  # DB (e.g. a card fetched before earlier place_at/3 calls re-indexed its
  # stage — top-insert on every create means this happens often). force_change
  # guarantees the UPDATE always writes :stage_id/:position rather than
  # silently no-op'ing when the stale in-memory value coincidentally matches
  # the new target.
  defp reposition({%Card{} = card, position}, stage_id) do
    changeset =
      card
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.force_change(:stage_id, stage_id)
      |> Ecto.Changeset.force_change(:position, position)

    case Repo.update(changeset) do
      {:ok, card} -> card
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # The MMF 05 seam, now live: a cross-stage move appends a :moved
  # timeline entry with both stage names snapshotted into meta. Routed
  # through Boards.stage_display_name/1 so a move into/out of a sub-lane
  # snapshots the human label ("Code · Review"), not the composite
  # internal Stage.name ("Code:Review") enable_lane/2 builds.
  defp emit_stage_changed(%Card{} = moved, previous_stage_id, %Stage{} = target_stage, actor) do
    from_stage = Repo.get!(Stage, previous_stage_id)

    {:ok, _entry} =
      Activity.log(moved, %{
        type: :moved,
        actor: actor,
        meta: %{
          "from_stage" => Boards.stage_display_name(from_stage),
          "to_stage" => Boards.stage_display_name(target_stage)
        }
      })
  end

  # Locks the board row so concurrent creates serialize, then bumps
  # `card_seq` and returns the newly allocated ref number. A rollback of
  # the surrounding transaction also reverts the bump, keeping refs
  # gap-free.
  defp allocate_ref_number(board_id) do
    board = Repo.one!(from b in Board, where: b.id == ^board_id, lock: "FOR UPDATE")
    ref_number = board.card_seq + 1

    {1, _} =
      Repo.update_all(from(b in Board, where: b.id == ^board_id), set: [card_seq: ref_number])

    ref_number
  end

  defp preload_owners_result({:ok, card}), do: {:ok, preload_owners(card)}
  defp preload_owners_result({:error, changeset}), do: {:error, changeset}

  # MMF 18: announce a created/edited card to every open board session.
  # Called only after the mutation (and its transaction, where there is
  # one) has committed; Events.broadcast/2 is fire-and-forget.
  defp broadcast_upserted({:ok, %Card{} = card} = result) do
    Events.broadcast(card.board_id, {:card_upserted, card})
    result
  end

  defp broadcast_upserted({:error, _changeset} = result), do: result

  defp log_status_changed({:ok, %Card{} = card} = result, from_status, actor) do
    if card.status != from_status do
      {:ok, _entry} =
        Activity.log(card, %{
          type: :status_changed,
          actor: actor,
          meta: %{"from_status" => to_string(from_status), "to_status" => to_string(card.status)}
        })
    end

    result
  end

  defp log_status_changed({:error, _changeset} = result, _from_status, _actor), do: result

  defp log_owners_changed(%Card{} = card, actor, meta) do
    {:ok, _entry} = Activity.log(card, %{type: :owners_changed, actor: actor, meta: meta})
  end

  # The label snapshotted into owners_changed meta — how the timeline
  # phrases the changed owner ("added AI as owner", "removed Ada …").
  defp owner_label(:agent), do: "AI"

  defp owner_label({:user, user_id}) do
    user = Repo.get!(User, user_id)
    user.name || user.email
  end

  defp preload_owners(nil), do: nil
  defp preload_owners(card_or_cards), do: Repo.preload(card_or_cards, card_preloads())

  # Cards travel with their owners (+user) and position-ordered sub_tasks, so the
  # board columns, the JSON, and any open drawer (including live-refreshed ones)
  # always have what they render — no downstream re-fetch or NotLoaded guard.
  defp card_preloads, do: [owners: :user, sub_tasks: from(st in SubTask, order_by: st.position)]

  # Inside set_sub_tasks/2's transaction: insert one checklist item with its
  # programmatic card_id + position; a bad title rolls the whole replace-all back.
  defp insert_sub_task!(%Card{} = card, attrs, position) do
    %SubTask{card_id: card.id, position: position}
    |> SubTask.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, sub_task} -> sub_task
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_owner_or_rollback(%Card{} = card, actor) do
    case insert_owner(card, actor) do
      {:ok, _owner} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_owner(%Card{} = card, :agent) do
    %CardOwner{card_id: card.id, actor_type: :agent}
    |> CardOwner.changeset()
    |> Repo.insert(on_conflict: :nothing)
  end

  defp insert_owner(%Card{} = card, {:user, user_id}) when is_integer(user_id) do
    %CardOwner{card_id: card.id, actor_type: :user, user_id: user_id}
    |> CardOwner.changeset()
    |> Repo.insert(on_conflict: :nothing)
  end

  defp owner_query(%Card{} = card, :agent) do
    from o in CardOwner, where: o.card_id == ^card.id and o.actor_type == ^:agent
  end

  defp owner_query(%Card{} = card, {:user, user_id}) do
    from o in CardOwner,
      where: o.card_id == ^card.id and o.actor_type == ^:user and o.user_id == ^user_id
  end

  defp reload_with_owners(%Card{} = card) do
    Card |> Repo.get!(card.id) |> Repo.preload(card_preloads())
  end

  defp insert_card(%Stage{} = stage, ref_number, attrs) do
    changeset =
      Card.changeset(
        %Card{board_id: stage.board_id, stage_id: stage.id, position: 0, ref_number: ref_number},
        attrs
      )

    case Repo.insert(changeset) do
      # RLY-1 item 5 — new cards land at the TOP of the stage. place_at/3 re-indexes
      # the whole stage to 1..n, shifting the existing cards down by one. Safe under
      # concurrency because create_card/3 already holds the board-row lock.
      {:ok, card} -> {:ok, place_at(card, stage, 0)}
      {:error, _changeset} = error -> error
    end
  end
end
