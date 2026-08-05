defmodule Relay.Talk do
  @moduledoc """
  Talk (ADR 0009): a person-driven execution lane. A person types in a card's terminal pane, one
  turn becomes a `node_jobs` row with `kind: :talk` and no run, an executor claims it through
  the SAME long-poll claim every flow node uses, and its output streams back as durable,
  ordered transcript rows.

  Three tables: `Schemas.TalkSession` (one per card), `Schemas.TalkTurn` (one per human
  message), `Schemas.TalkEvent` (one per rendered line, append-only).

  **Ordering is `seq`, never a timestamp.** `append_events/2` assigns it server-side inside one
  transaction that also bumps `talk_sessions.last_event_seq`, so two concurrent batches cannot
  interleave into the same number. Delivery from the executor is at-least-once, so a batch may
  arrive twice — `(talk_turn_id, client_seq)` is unique and a replay is dropped, silently and
  without a second broadcast.

  **The pin.** The session records which executor holds the `claude` session. It is written by
  `finish_turn/3` (from the claiming executor recorded on the job row) and read by
  `post_message/3`, which copies it onto the next job's `executor_name`. That is why
  `Relay.Runs.claim_next_job/1` needs no Talk knowledge: the pin is expressed in the same column
  an exclusive run's pin already uses.

  **Known step-1 limitation.** A turn whose executor dies stays `claimed` — the orphan reaper
  deliberately ignores talk jobs (requeueing one would hand a resumed session to a machine that
  does not hold it). `stop_turn/1` revokes unconditionally, so a person can always end it.

  **Not here in step 1**: receipts and `:field_changed` ([AC16]), `awaiting` turns ([AC17]), the
  write lease and `bin/relay say` ([AC18]), card-level executor pinning ([AC12]). A talk turn
  does **not** move the card's baton (ADR 0009 §6).

  PubSub: `card:<card_id>:talk`, carrying `{:talk_event, event}` and `{:talk_turn_changed, turn}`.
  Broadcast from this context only.
  """

  use Boundary, deps: [Relay.Cards, Relay.Repo, Relay.Runs, Schemas]

  import Ecto.Query

  alias Relay.Cards
  alias Relay.Repo
  alias Relay.Runs
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.NodeJob
  alias Schemas.TalkEvent
  alias Schemas.TalkSession
  alias Schemas.TalkTurn
  alias Schemas.User

  @pubsub Relay.PubSub
  @reportable_statuses TalkTurn.reportable_statuses()

  @doc "The per-card Talk topic."
  def topic(card_id), do: "card:#{card_id}:talk"

  @doc "Subscribes the calling process to `card_id`'s Talk topic."
  def subscribe(card_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(card_id))

  @doc "Unsubscribes the calling process from `card_id`'s Talk topic."
  def unsubscribe(card_id), do: Phoenix.PubSub.unsubscribe(@pubsub, topic(card_id))

  @doc """
  The card's session, created on first use. The seed is recomputed on every call: it describes
  what the NEXT turn will be handed, so a stale summary would be a lie about the injected
  context rather than a cosmetic nit.

  The card is re-read here rather than trusted: the drawer's caller holds
  `Cards.get_card_light_by_ref/2`'s projection until its async body fill lands, and that
  projection nils exactly the four heavy fields `build_seed/1` reads. Trusting it let `t`
  pressed inside that window persist a `0 fields` seed — the lie this docstring forbids.
  """
  def session_for_card(%Card{} = card) do
    seed = Card |> Repo.get!(card.id) |> build_seed()

    # `on_conflict: :nothing` returns a struct with a nil id when a concurrent insert won the
    # unique index, so the row is always re-read rather than trusted from the insert.
    %TalkSession{card_id: card.id}
    |> TalkSession.changeset(%{})
    |> Repo.insert(on_conflict: :nothing, conflict_target: :card_id)

    TalkSession
    |> Repo.get_by!(card_id: card.id)
    |> TalkSession.changeset(%{seed_summary: seed.summary, seed_fields: seed.fields})
    |> Repo.update!()
  end

  @doc """
  The card's session as it already stands, or `nil` — the read-only twin of `session_for_card/1`.

  `session_for_card/1` inserts the row and rewrites the seed on every call, so it cannot be used
  to merely LOOK at a transcript: opening Talk on an archived board would write to a board the
  UI promises is read-only (RE268).
  """
  def get_session(%Card{} = card), do: Repo.get_by(TalkSession, card_id: card.id)

  @doc """
  Posts one human message: appends its `:user` line, inserts a `:queued` turn and the talk job
  that carries it, all in one transaction. The job is pinned to the session's holder (nil on the
  first turn, which is what lets any executor take it and BECOME the holder) and carries the
  stored `claude_session_id` as `resume_session`.

  Refuses a blank message and refuses a second turn while one is in flight — a session is one
  conversation, and two concurrent `claude -p --resume` calls on one session id is exactly the
  silent-corruption case ADR 0009 §3 exists to prevent.
  """
  def post_message(%Card{} = card, %User{} = author, text) when is_binary(text) do
    prompt = String.trim(text)

    if prompt == "" do
      {:error, :blank}
    else
      session = session_for_card(card)
      fn -> do_post(card, session, author, prompt) end |> Repo.transaction() |> handle_post(card)
    end
  end

  defp handle_post({:ok, {turn, event}}, card) do
    broadcast(card.id, {:talk_event, event})
    broadcast(card.id, {:talk_turn_changed, turn})
    # Wakes the claim long-poll: `{:run_changed, card_id}` is already one of the tags
    # `RelayWeb.Api.NodeJobController.maybe_wait/4` retries a claim on, so a talk job needs no
    # second wake channel.
    Runs.broadcast_run_changed(card.board_id, card.id)
    {:ok, turn}
  end

  defp handle_post({:error, :turn_in_flight}, _card), do: {:error, :turn_in_flight}

  # The "one turn in flight" guard has to live INSIDE the transaction, after the same session
  # row lock `insert_events!/3` takes — otherwise it is check-then-act: two near-simultaneous
  # posts can both see no active turn before either has committed one, and both insert a
  # `:queued` turn against the same `resume_session` (ADR 0009 §3). Locking first serializes
  # the check against any other post's commit.
  defp do_post(card, session, author, prompt) do
    locked = lock_session!(session.id)

    if active_turn(locked) do
      Repo.rollback(:turn_in_flight)
    end

    turn =
      %TalkTurn{talk_session_id: locked.id, author_id: author.id, prompt: prompt}
      |> TalkTurn.changeset(%{status: :queued})
      |> Repo.insert!()

    # The human's own line is `client_seq: 0`; the executor numbers its lines from 1, so the
    # two writers of one turn's transcript can never collide on the unique index.
    [event] = insert_events!(locked, turn, [%{"client_seq" => 0, "kind" => "user", "text" => prompt, "dim" => false}])

    payload = %{
      "turn_id" => turn.id,
      "ref" => Cards.ref(board_of(card), card),
      "prompt" => prompt,
      "author" => author.name || author.email,
      "branch" => card.branch,
      "resume_session" => locked.claude_session_id,
      "seed" => %{"summary" => locked.seed_summary, "fields" => locked.seed_fields}
    }

    job = Runs.insert_talk_job!(card, payload, locked.pinned_executor_name)
    turn = turn |> TalkTurn.changeset(%{node_job_id: job.id}) |> Repo.update!()
    {turn, event}
  end

  @doc """
  Appends a batch of executor-sent lines. `seq` is assigned here (never by the executor); a line
  whose `(turn, client_seq)` already exists is dropped without a broadcast, which is what makes
  the executor's retry safe. Returns only the lines that were genuinely new.
  """
  def append_events(%TalkTurn{} = turn, raw) when is_list(raw) do
    session = Repo.get!(TalkSession, turn.talk_session_id)
    card_id = session.card_id

    {:ok, stored} = Repo.transaction(fn -> insert_events!(session, turn, raw) end)
    Enum.each(stored, &broadcast(card_id, {:talk_event, &1}))
    {:ok, stored}
  end

  # One transaction, one lock: SELECT ... FOR UPDATE on the session row serialises seq
  # assignment, so two concurrent batches can never claim the same number.
  defp insert_events!(session, turn, raw) do
    locked = lock_session!(session.id)

    seen =
      from(e in TalkEvent, where: e.talk_turn_id == ^turn.id, select: e.client_seq)
      |> Repo.all()
      |> MapSet.new()

    {stored, last} =
      raw
      |> Enum.map(&normalize_event/1)
      |> Enum.reject(&(&1 == :invalid or &1.client_seq in seen))
      |> Enum.uniq_by(& &1.client_seq)
      |> Enum.reduce({[], locked.last_event_seq}, fn attrs, {acc, seq} ->
        next = seq + 1

        event =
          %TalkEvent{talk_session_id: session.id, talk_turn_id: turn.id, seq: next}
          |> TalkEvent.changeset(%{
            kind: attrs.kind,
            text: attrs.text,
            dim: attrs.dim,
            client_seq: attrs.client_seq
          })
          |> Repo.insert!()

        {[event | acc], next}
      end)

    if last != locked.last_event_seq do
      Repo.update_all(from(s in TalkSession, where: s.id == ^session.id), set: [last_event_seq: last])
    end

    Enum.reverse(stored)
  end

  # An unknown (but string) kind degrades to `:out` rather than raising. EVERY other shape
  # problem drops the one line (`:invalid`): not a map; no integer `client_seq`; a non-boolean
  # `dim`; a `text` that is missing, blank or not a string; a `kind` that is present but not a
  # string. The executor is untrusted input, and a mangled line must never cost the whole batch —
  # not even the batch containing it. Each of those reached `Repo.insert!` before RE268's round-2
  # review: a blank `text` raised `Ecto.InvalidChangesetError` (the changeset requires `:text`)
  # and a non-string `text`/`kind` raised `Protocol.UndefinedError` in `to_string/1` — neither an
  # `{:error, _}` the fallback controller can render, so the batch 500'd and rolled back whole.
  defp normalize_event(raw) when not is_map(raw), do: :invalid

  defp normalize_event(raw) do
    client_seq = field(raw, :client_seq)
    dim = field(raw, :dim) || false
    text = field(raw, :text)
    kind = field(raw, :kind)

    if valid_event?(client_seq, dim, text, kind) do
      %{client_seq: client_seq, kind: normalize_kind(kind), text: text, dim: dim}
    else
      :invalid
    end
  end

  # The batch arrives as JSON (string keys) from the executor and as atom-keyed maps from
  # `do_post/4`'s own seed line, so both are read here rather than at every call site.
  defp field(raw, key), do: raw[Atom.to_string(key)] || raw[key]

  # `client_seq` is an int4 column, so an in-range check is part of validity, not a nicety: an
  # out-of-range integer passes `is_integer/1` and the Ecto cast, then raises Postgrex 22003 from
  # `Repo.insert!` — a 500 that rolls the whole batch back and loses every VALID line with it.
  @client_seq_max 2_147_483_647

  defp valid_event?(client_seq, dim, text, kind) do
    is_integer(client_seq) and client_seq >= 0 and client_seq <= @client_seq_max and
      is_boolean(dim) and is_binary(text) and
      String.trim(text) != "" and (is_nil(kind) or is_binary(kind))
  end

  defp normalize_kind(kind), do: Enum.find(TalkEvent.kinds(), :out, &(Atom.to_string(&1) == kind))

  @doc """
  Marks the turn carried by a just-claimed talk job `:claimed` — an executor now holds it and
  `claude -p` is about to run. Called by `RelayWeb.Api.NodeJobController` off the claim it just
  granted, which is what keeps `Relay.Runs` free of Talk knowledge: the run lifecycle claims a
  job, and only Talk knows a job can carry a turn.

  Only a `:queued` turn moves. Stop revokes the job but leaves it claimable for the moment
  before the executor notices, and a claim must never drag a `:stopped` turn back to live.
  """
  def mark_claimed(%NodeJob{kind: :talk} = job) do
    turn = Repo.one(from t in TalkTurn, where: t.node_job_id == ^job.id)

    cond do
      is_nil(turn) ->
        {:error, :no_turn}

      turn.status != :queued ->
        {:error, :not_queued}

      true ->
        updated = turn |> TalkTurn.changeset(%{status: :claimed}) |> Repo.update!()
        session = Repo.get!(TalkSession, updated.talk_session_id)
        broadcast(session.card_id, {:talk_turn_changed, updated})
        {:ok, updated}
    end
  end

  def mark_claimed(%NodeJob{}), do: {:error, :not_talk}

  @doc """
  Ends a turn. `:done` persists the executor's `claude_session_id` on the session — the single
  thing that makes the next turn a continuation — and records the claiming executor as the
  session's pin. `:stopped` and `:failed` leave both alone: a turn that never finished cannot
  vouch for a session id.

  **First writer wins**, mirroring `stop_turn/1`'s guard: only an active turn moves. A turn the
  person already Stopped must not be dragged back to `:done` by a `claude -p` that finished in
  the window before the revoke reached the executor — that would resurrect a terminal state AND
  let a turn that never finished vouch for a session id. An already-finalised turn still returns
  `{:ok, turn}` (the `:already_finalized` precedent in
  `RelayWeb.Api.NodeJobController.resolve_and_report/4`), so the executor's at-least-once retry
  still 200s instead of re-broadcasting and rewriting the pin.
  """
  def finish_turn(%TalkTurn{} = turn, status, attrs \\ %{}) when status in @reportable_statuses do
    turn = Repo.get!(TalkTurn, turn.id)

    if turn.status in TalkTurn.active_statuses() do
      do_finish_turn(turn, status, attrs)
    else
      {:ok, turn}
    end
  end

  # One transaction, because the steps are not independent: `finish_talk_job!/1` committing while
  # the turn update raises leaves the job `:done` and the turn `:claimed` — and from there
  # `active_turn/1` keeps returning it, `post_message/3` refuses every later turn with
  # `:turn_in_flight`, the orphan reaper skips talk jobs by design, and the executor's
  # at-least-once retry re-raises forever. That wedges the card's Talk until a human hits Stop.
  # The split state is reachable from ANY raise between the job update and the turn update, not
  # just from bad input, so the fix belongs here rather than only at the controller.
  defp do_finish_turn(turn, status, attrs) do
    {:ok, {card_id, updated}} =
      Repo.transaction(fn ->
        session = Repo.get!(TalkSession, turn.talk_session_id)
        job = turn.node_job_id && Runs.get_job(turn.node_job_id)

        if job && job.state in NodeJob.active_states(), do: Runs.finish_talk_job!(job)
        if job && status == :done, do: persist_session(session, job, attrs)

        updated =
          turn |> TalkTurn.changeset(%{status: status, detail: attrs[:detail]}) |> Repo.update!()

        {session.card_id, updated}
      end)

    # After commit, never inside: the module's own convention (`handle_post/2`, `append_events/2`)
    # and the reason for it — a rollback after broadcasting announces a change that did not happen.
    broadcast(card_id, {:talk_turn_changed, updated})
    {:ok, updated}
  end

  defp persist_session(session, job, attrs) do
    session
    |> TalkSession.changeset(%{
      claude_session_id: attrs[:session_id] || session.claude_session_id,
      pinned_executor_name: job.executor_name || session.pinned_executor_name
    })
    |> Repo.update!()
  end

  @doc """
  The Stop button (ADR 0009 §1). Revokes the job — the heartbeat's `Relay.Runs.revoked_among/2`
  then names it and the executor kills the running `claude -p` — and ends the turn `:stopped`,
  a normal non-error state whose partial output stays in the transcript. Server-side and
  unconditional, so a turn whose executor is already gone still ends.
  """
  def stop_turn(%TalkTurn{} = turn) do
    turn = Repo.get!(TalkTurn, turn.id)

    if turn.status in TalkTurn.active_statuses() do
      job = turn.node_job_id && Runs.get_job(turn.node_job_id)
      if job, do: Runs.revoke_talk_job(job)

      session = Repo.get!(TalkSession, turn.talk_session_id)
      updated = turn |> TalkTurn.changeset(%{status: :stopped}) |> Repo.update!()
      broadcast(session.card_id, {:talk_turn_changed, updated})
      {:ok, updated}
    else
      {:error, :not_active}
    end
  end

  @doc "The session's visible scrollback in render order — `seq` ascending, above `cleared_through_seq`."
  def events(%TalkSession{} = session, opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)

    # `limit` must bound the NEWEST lines, not the oldest — take the highest `limit` seqs
    # (`desc`) then reverse in memory, so a long session's default read shows the recent
    # tail instead of stalling at seq 1..limit forever.
    from(e in TalkEvent,
      where: e.talk_session_id == ^session.id and e.seq > ^session.cleared_through_seq,
      order_by: [desc: e.seq],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc "`/clear`: hides everything written so far. Deletes nothing — the transcript is a record, and hiding it is a view decision."
  def clear(%TalkSession{} = session) do
    session = Repo.get!(TalkSession, session.id)

    updated =
      session
      |> TalkSession.changeset(%{cleared_through_seq: session.last_event_seq})
      |> Repo.update!()

    {:ok, updated}
  end

  @doc "The session's live turn (`queued` or `claimed`), or nil. What makes the pane show Stop."
  def active_turn(%TalkSession{} = session) do
    Repo.one(
      from t in TalkTurn,
        where: t.talk_session_id == ^session.id and t.status in ^TalkTurn.active_statuses(),
        order_by: [desc: t.id],
        limit: 1
    )
  end

  @doc "The turn with `id`, or nil."
  def get_turn(id) when is_integer(id), do: Repo.get(TalkTurn, id)

  @doc "The board a turn belongs to — the API's authorization scope."
  def board_id_of(%TalkTurn{} = turn) do
    Repo.one!(
      from t in TalkTurn,
        join: s in TalkSession,
        on: s.id == t.talk_session_id,
        join: c in Card,
        on: c.id == s.card_id,
        where: t.id == ^turn.id,
        select: c.board_id
    )
  end

  @doc """
  What the next turn will be handed, as the seed line renders it: a one-line `summary` and one
  padded `label`/`value` row per injected field, matching the `TALK: terminal session` block of
  `docs/designs/Relay Card Detail v5.dc.html`.
  """
  def build_seed(%Card{} = card) do
    fields =
      Enum.filter(
        [
          {"description", card.description},
          {"acceptance", card.acceptance_criteria},
          {"spec", card.spec},
          {"plan", card.plan}
        ],
        fn {_label, value} -> present?(value) end
      )

    runs = Runs.list_runs(card)
    steps = Runs.plan_task_count(card.plan)

    summary =
      [
        "#{length(fields)} fields",
        if(steps > 0, do: "plan #{steps} steps", else: "no plan yet"),
        "#{length(runs)} runs",
        if(card.rejection, do: "changes requested")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    rows =
      Enum.map(fields, fn {label, value} -> %{"label" => label, "value" => one_line(value)} end) ++
        [
          %{"label" => "runs", "value" => "#{length(runs)} on this card"},
          %{"label" => "flow", "value" => card.branch || "no branch yet"}
        ]

    %{summary: summary, fields: rows}
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp one_line(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp board_of(%Card{} = card), do: Repo.get!(Board, card.board_id)

  # SELECT ... FOR UPDATE on the session row: the one lock every writer serialises through,
  # whether assigning `seq` (`insert_events!/3`) or guarding "one turn in flight" (`do_post/4`).
  defp lock_session!(session_id) do
    Repo.one!(from s in TalkSession, where: s.id == ^session_id, lock: "FOR UPDATE")
  end

  defp broadcast(card_id, message), do: Phoenix.PubSub.broadcast(@pubsub, topic(card_id), message)
end
