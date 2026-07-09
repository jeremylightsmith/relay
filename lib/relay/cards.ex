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
  alias Schemas.User

  # Approve/reject append the card to the bottom of the target stage;
  # move_card/4 clamps this into range.
  @append_index 1_000_000

  @doc """
  Creates a card in `stage` from user-supplied `attrs` (`:title`, optional
  `:tag`), attributed to `actor` (`:agent | {:user, user_id}`, defaults to
  `:agent` — the API identity; web callers pass the signed-in user),
  returning `{:ok, card}` or `{:error, changeset}`.

  The next per-board `ref_number` is allocated by locking the board row
  (`SELECT ... FOR UPDATE`) and bumping `Board.card_seq` inside the
  transaction, so refs are sequential and gap-free even under concurrent
  creates. The card is appended to the bottom of the stage. A successful
  create logs a `:created` activity entry (MMF 07) attributed to `actor`.
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
  Returns all of `board`'s cards, ordered by stage then `position` — the
  render order within each stage column.
  """
  def list_cards(%Board{id: board_id}) do
    Repo.all(
      from c in Card,
        where: c.board_id == ^board_id,
        order_by: [asc: c.stage_id, asc: c.position, asc: c.id],
        preload: [owners: :user]
    )
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
  Sets the card's baton status (`:queued | :working | :needs_input |
  :in_review | :done`) and optional `progress` (0–100) from `attrs`,
  attributed to `actor` (`:agent | {:user, user_id}`, defaults to
  `:agent`), returning `{:ok, card}` (owners preloaded) or
  `{:error, changeset}`. Status only ever changes through this explicit
  call — never as a side effect of moving a card. Logs a
  `:status_changed` activity entry (MMF 07) only when the status value
  actually changes (a progress-only update logs nothing). Entering
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
  Adds one owner actor to the card, attributed to `actor`
  (`:agent | {:user, user_id}`, defaults to `:agent`), returning
  `{:ok, card}` with owners preloaded. Adding an actor that is already an
  owner is an ok no-op that logs nothing; otherwise logs an
  `:owners_changed` activity entry (MMF 07) with the owner label.
  """
  def add_owner(%Card{} = card, owner_actor, actor \\ :agent) do
    already_owner? = Repo.exists?(owner_query(card, owner_actor))

    case insert_owner(card, owner_actor) do
      {:ok, _owner} ->
        if not already_owner? do
          log_owners_changed(card, actor, %{"action" => "added", "owner" => owner_label(owner_actor)})
        end

        broadcast_upserted({:ok, reload_with_owners(card)})

      {:error, changeset} ->
        {:error, changeset}
    end
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
  the agent is among the owners (human owners render paused), `:human`
  when only humans own it, `nil` when unowned. Never stored — always
  derived. Accepts any map with a loaded `owners` list so components can
  use it on plain maps too.
  """
  def active_owner_type(%{owners: owners}) when is_list(owners) do
    cond do
      Enum.any?(owners, &(&1.actor_type == :agent)) -> :ai
      owners != [] -> :human
      true -> nil
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

        if moved.stage_id != previous_stage_id do
          emit_stage_changed(moved, previous_stage_id, target_stage, actor)
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

  @doc """
  Approves the card past its approval gate (MMF 13). Allowed when the
  card's stage — or its parent, for a card sitting in a sub-lane — has
  `approval_gate` set; otherwise returns `{:error, :not_gated}`. Moves
  the card to the bottom of the next main stage by position (sub-lane
  children are never "next"; from a sub-lane, next = the first main
  stage after the parent), arriving `:working` when that stage is meant
  for AI and `:queued` when meant for a human. At the board's last main
  stage there is no move — the card's status becomes `:done` in place.
  Logs an `:approved` activity entry (from/to stage display names in
  meta) attributed to `actor`, and reuses `move_card`/`set_status`, so
  the usual `{:card_moved}`/`{:card_upserted}`/`{:timeline_appended}`
  events fire. Reused verbatim by the API (MMF 09) and the drawer
  (MMF 15).
  """
  def approve(%Card{} = card, actor \\ :agent) do
    case fetch_gate(card) do
      {:ok, from_stage, gate} ->
        case Boards.next_main_stage(gate) do
          nil -> approve_in_place(card, from_stage, actor)
          %Stage{} = target -> route(card, from_stage, target, :approved, nil, actor)
        end

      {:error, :not_gated} ->
        {:error, :not_gated}
    end
  end

  @doc """
  Rejects the card at its approval gate (MMF 13) — a thin wrapper over
  `send_back/4`. Resolves the gate under the same rule as `approve/2`
  (`{:error, :not_gated}` otherwise), picks the target = `opts[:to]` when given
  else the gate's configured `reject_to` (or the gate's own main lane when
  unset), then sends the card back. `opts[:to]` may be a `%Stage{}` or a stage
  id and must satisfy `send_back`'s backward/main-lane rule.
  """
  def reject(%Card{} = card, note, actor \\ :agent, opts \\ []) when is_binary(note) do
    case fetch_gate(card) do
      {:ok, _from_stage, gate} -> send_back(card, gate_reject_target(gate, opts), note, actor)
      {:error, :not_gated} -> {:error, :not_gated}
    end
  end

  @doc """
  The universal send-back primitive (RLY-30): bounce `card` **backward** to a
  main-lane `target` (a `%Stage{}` or its id) whose position is at or before the
  card's current main-lane stage, attributed to `actor`. It moves the card to
  the bottom of `target` with the target's arrival status, posts `note` as a
  comment (keeping the human-readable thread intact), logs a `:rejected`
  activity entry, and sets the card's single open `rejection` embed (snapshotting
  from/to stage names, the actor's display name, and the timestamp) — replacing
  any existing open rejection. Returns `{:ok, card}` (rejection set, owners
  preloaded) or `{:error, :missing_note | :invalid_target | changeset}`. A blank
  note is rejected before anything moves; a target that is not a main-lane stage
  on this board, or is positioned after the card's current main stage, is
  `{:error, :invalid_target}`.
  """
  def send_back(card, target, note, actor \\ :agent)

  def send_back(%Card{board_id: board_id} = card, target_id, note, actor)
      when is_integer(target_id) and is_binary(note) do
    case Repo.get_by(Stage, id: target_id, board_id: board_id) do
      %Stage{} = target -> send_back(card, target, note, actor)
      nil -> {:error, :invalid_target}
    end
  end

  def send_back(%Card{} = card, %Stage{} = target, note, actor) when is_binary(note) do
    from_stage = current_main_stage(card)

    cond do
      String.trim(note) == "" ->
        {:error, :missing_note}

      not send_back_target?(card, from_stage, target) ->
        {:error, :invalid_target}

      true ->
        with {:ok, moved} <- move_card(card, target, @append_index, actor),
             {:ok, updated} <- set_status(moved, %{status: arrival_status(target)}, actor),
             :ok <- attach_note(updated, note, actor) do
          log_gate(updated, :rejected, actor, from_stage, target, note)
          {:ok, put_rejection(updated, from_stage, target, note, actor)}
        end
    end
  end

  @doc """
  Marks the card `:done` in place (the drawer's "Mark done") and clears any open
  rejection — the work has been accepted. Returns `{:ok, card}` or
  `{:error, changeset}`.
  """
  def mark_done(%Card{} = card, actor \\ :agent) do
    case set_status(card, %{status: :done}, actor) do
      {:ok, updated} -> {:ok, clear_rejection(updated)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Blocks the card on a human (MMF 14): sets status `:needs_input` — which
  stamps `blocked_since` (see `Schemas.Card.status_changeset/2`) — posts
  `question` as a comment from `actor`, and logs a `:needs_input` activity
  entry with the question in `meta` (the durable record the drawer's
  question panel reads). The MMF 09 `POST /api/cards/:ref/needs-input`
  endpoint routes here. Reuses `set_status`/`Relay.Activity`, so the usual
  `{:card_upserted}` / `{:timeline_appended}` events fire (MMF 18).
  """
  def request_input(%Card{} = card, question, actor \\ :agent) when is_binary(question) do
    with {:ok, updated} <- set_status(card, %{status: :needs_input}, actor),
         {:ok, _comment} <- Activity.add_comment(updated, %{actor: actor, body: question}),
         {:ok, _entry} <-
           Activity.log(updated, %{type: :needs_input, actor: actor, meta: %{"question" => question}}) do
      {:ok, updated}
    end
  end

  @doc """
  Answers a blocked card's question (MMF 14): posts `answer` as a comment
  from `actor`, flips status to `:working` when the card's stage is meant
  for the AI (the agent resumes) or `:queued` otherwise — clearing
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

  # Where an answered card resumes: the stage's meant-for owner decides
  # (same rule as approve/reject arrivals).
  defp resume_status(%Card{stage_id: stage_id}), do: arrival_status(Repo.get!(Stage, stage_id))

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

  # The gate governing the card: its own stage when main-lane, else the
  # sub-lane's parent. {:error, :not_gated} when that stage isn't a gate.
  defp fetch_gate(%Card{stage_id: stage_id}) do
    stage = Repo.get!(Stage, stage_id)
    gate = if stage.lane == :main, do: stage, else: Repo.get!(Stage, stage.parent_id)

    if gate.approval_gate, do: {:ok, stage, gate}, else: {:error, :not_gated}
  end

  defp reject_target(%Stage{reject_to_stage_id: nil} = gate), do: gate
  defp reject_target(%Stage{reject_to_stage_id: target_id}), do: Repo.get!(Stage, target_id)

  # The gate reject target: an explicit :to (Stage or id) wins, else the gate's
  # configured reject_to (or the gate itself when unset). send_back/4 validates it.
  defp gate_reject_target(gate, opts) do
    case Keyword.get(opts, :to) do
      nil -> reject_target(gate)
      %Stage{} = target -> target
      id when is_integer(id) -> id
    end
  end

  # The main-lane stage governing the card: its own stage when main-lane, else
  # its sub-lane's parent. Send-back targets are compared against this stage's
  # position.
  defp current_main_stage(%Card{stage_id: stage_id}) do
    stage = Repo.get!(Stage, stage_id)
    if stage.lane == :main, do: stage, else: Repo.get!(Stage, stage.parent_id)
  end

  # A valid send-back target is a main-lane stage on the card's board positioned
  # at or before the card's current main stage (never forward). The gate's
  # nil-target reject lands the card in its own stage, so "at" (==) is allowed;
  # the universal drawer control only ever offers strictly-earlier stages.
  defp send_back_target?(%Card{board_id: bid}, %Stage{} = from, %Stage{lane: :main, board_id: bid} = target),
    do: target.position <= from.position

  defp send_back_target?(_card, _from, _target), do: false

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

  # Shared approve/reject transition: move to the bottom of `target`, set
  # the arrival status, attach the note (rejects only), then log the
  # :approved/:rejected entry. A nil-target reject resolves to the gate
  # itself, so a main-lane card "moves" within its own stage (no :moved
  # entry — move_card only logs cross-stage moves).
  defp route(%Card{} = card, from_stage, %Stage{} = target, type, note, actor) do
    with {:ok, moved} <- move_card(card, target, @append_index, actor),
         {:ok, updated} <- set_status(moved, %{status: arrival_status(target)}, actor),
         :ok <- attach_note(updated, note, actor) do
      log_gate(updated, type, actor, from_stage, target, note)
      {:ok, clear_rejection(updated)}
    end
  end

  # Approve at the board's last main stage: :done in place, no move.
  defp approve_in_place(%Card{} = card, from_stage, actor) do
    case set_status(card, %{status: :done}, actor) do
      {:ok, updated} ->
        log_gate(updated, :approved, actor, from_stage, from_stage, nil)
        {:ok, clear_rejection(updated)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp arrival_status(%Stage{owner: :ai}), do: :working
  defp arrival_status(%Stage{owner: :human}), do: :queued

  defp attach_note(_card, nil, _actor), do: :ok

  defp attach_note(%Card{} = card, note, actor) do
    case Activity.add_comment(card, %{actor: actor, body: note}) do
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
  # rewritten 1..n (updates are no-ops for cards whose row is unchanged).
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

  defp reposition({%Card{} = card, position}, stage_id) do
    case Repo.update(Ecto.Changeset.change(card, stage_id: stage_id, position: position)) do
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
  defp preload_owners(card_or_cards), do: Repo.preload(card_or_cards, owners: :user)

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
    Card |> Repo.get!(card.id) |> Repo.preload(owners: :user)
  end

  defp insert_card(%Stage{} = stage, ref_number, attrs) do
    %Card{
      board_id: stage.board_id,
      stage_id: stage.id,
      position: next_position(stage),
      ref_number: ref_number
    }
    |> Card.changeset(attrs)
    |> Repo.insert()
  end

  # New cards append to the bottom of the stage. Safe under concurrency
  # because the caller already holds the board-row lock.
  defp next_position(%Stage{id: stage_id}) do
    (Repo.one(from c in Card, where: c.stage_id == ^stage_id, select: max(c.position)) || 0) + 1
  end
end
