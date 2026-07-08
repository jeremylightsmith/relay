# Plan — MMF 14: "Needs input" question ↔ answer flow

**Spec:** `docs/superpowers/specs/2026-07-08-needs-input-flow-design.md`
**Mockup:** `docs/designs/Relay Board.dc.html` (drawer blocked panel ≈ lines 398–405; board badge ≈ lines 127–130)
**Branch:** trunk-based on `main`

## Goal

When the AI is unsure it asks instead of guessing: an agent (via `POST /api/cards/:ref/needs-input`)
or a human blocks a card into `:needs_input` with a question; the board card shows its existing
amber NEEDS INPUT treatment (MMF 06 — unchanged); the drawer renders the mockup's amber
"RELAY AI NEEDS YOUR INPUT" panel with the latest question and an inline answer composer
("Send to AI →"); answering logs the answer, returns the card to the AI's queue
(`:working` on an AI-meant stage, `:queued` otherwise), and clears the block — with the whole
exchange living permanently in the timeline and retrievable by the agent through
`GET /api/cards/:ref`.

## Architecture

- **The question lives in the timeline, not on the card.** No `Card.question` field. A new
  first-class context function `Relay.Cards.request_input(card, question, actor \\ :agent)`
  does three things through the existing seams: sets status `:needs_input` via `set_status/3`
  (which now stamps `blocked_since`), posts the question as a comment from `actor`
  (`Relay.Activity.add_comment/2`), and logs a `:needs_input` activity entry with
  `meta: %{"question" => question}` (`Relay.Activity.log/2`) — the durable record the drawer
  reads. The MMF 09 `POST /api/cards/:ref/needs-input` controller action refactors onto it
  (behaviour-preserving: same status flip + question comment as today, plus the new entry).
- **New `Card.blocked_since`** (nullable `:utc_datetime`). Managed inside
  `Schemas.Card.status_changeset/2` so EVERY status path (drawer status control, API PATCH,
  approve/reject, request/answer) keeps the invariant: stamped when the status *changes to*
  `:needs_input`, cleared when it *changes to* anything else, untouched when the status isn't
  changing (progress-only updates). Never cast from user input.
- **Answering = `Relay.Cards.answer_input(card, answer, actor \\ :agent)`**: posts the answer
  as a comment from `actor`, flips status to `:working` when the card's stage is meant for the
  AI (`Stage.owner == :ai`, reusing the existing private `arrival_status/1`) or `:queued`
  otherwise (clearing `blocked_since` via the changeset), and logs an `:input_answered`
  activity entry. `Schemas.Activity` gains types `:needs_input` and `:input_answered`.
- **The agent consumes the answer via the existing API** — the answer comment and
  `:input_answered` entry appear in `GET /api/cards/:ref`'s timeline; the status flip is
  visible in the card JSON. No new endpoint.
- **All transitions broadcast for free (MMF 18)**: `set_status`, `add_comment`, and `log`
  already emit `{:card_upserted, card}` / `{:timeline_appended, card_id, entry}`, so the amber
  state appears/clears live in every session. `RelayWeb.BoardLive` already applies these in
  `handle_info/2`; the drawer refresh path (`refresh_card/2`) just also recomputes the latest
  question.
- **Drawer UI (LiveView only, per ADR 0001):** `card_drawer/1` in
  `RelayWeb.CoreComponents` gains an amber panel (rendered above the Description section when
  `card.status == :needs_input`) with the mockup's exact styling, a "waiting Xh" aging hint
  derived from `blocked_since`, the latest question, a 3-row textarea, and the "Send to AI →"
  button submitting `phx-submit="answer_input"`. IDs: `#needs-input-panel`,
  `#needs-input-answer`, `#needs-input-send` (plus `#needs-input-form`,
  `#needs-input-question`, `#needs-input-waiting`).

## Tech

Phoenix 1.8 + LiveView, Ecto/Postgres, daisyUI/Tailwind v4, `boundary`-enforced contexts,
ExMachina factories, `Phoenix.LiveViewTest`. No new dependencies.

## Global constraints

- `mix precommit` MUST pass at the end of every task (compile with warnings-as-errors,
  `mix format` with Styler, `credo --strict`, `sobelow`, `deps.audit`, full test suite).
- Context boundaries: the web layer calls the domain only through `Relay`'s exported
  contexts; `Relay.Cards` already declares deps on `Relay.Activity`, `Relay.Boards`,
  `Relay.Events`, `Relay.Repo`, `Schemas` — no boundary changes needed.
- Keep the actor model: `:agent` for API calls, `{:user, user_id}` for drawer actions
  (BoardLive's `current_actor/1`).
- `blocked_since` is set programmatically, never cast from user input (do NOT add it to any
  `cast` list).
- Broadcasts are emitted by contexts only (never controllers/LiveViews) — reuse the existing
  `set_status`/`add_comment`/`log` paths; do not add new `Events.broadcast` calls.
- HEEx: list syntax for multi-value `class` attrs; `{...}` in attrs; `<.input>` for form
  inputs (overriding `class` on `<.input>` drops all default classes — fully style it);
  forms via `to_form/2`; unique DOM ids on key elements; no inline `<script>`.
- Match the mockup's inline amber oklch values exactly (cited per element in Task 2).
- Predicate functions end in `?`, never start with `is_`.
- Tests assert via `element/2`/`has_element?/2` on ids/classes, not raw HTML.

---

### Task 1: Domain — `blocked_since`, `Cards.request_input/3`, `Cards.answer_input/3`, API refactor

**Files**
- Create: `priv/repo/migrations/<timestamp>_add_blocked_since_to_cards.exs` (via
  `mix ecto.gen.migration add_blocked_since_to_cards`)
- Modify: `lib/schemas/card.ex`, `lib/schemas/activity.ex`, `lib/relay/cards.ex`,
  `lib/relay_web/controllers/api/card_controller.ex`
- Test (create): `test/relay/cards_needs_input_test.exs`
- Test (modify): `test/relay/context_broadcasts_test.exs`,
  `test/relay_web/api/card_actions_test.exs`

**Interfaces**

*Consumes (already shipped):*
- `Relay.Cards.set_status(%Schemas.Card{}, attrs, actor \\ :agent) :: {:ok, %Schemas.Card{}} | {:error, Ecto.Changeset.t()}`
- `Relay.Cards.get_card_by_ref(%Schemas.Board{}, ref :: String.t()) :: %Schemas.Card{} | nil`
- `Relay.Activity.add_comment(%Schemas.Card{}, %{actor: actor, body: String.t()}) :: {:ok, %Schemas.Comment{}} | {:error, Ecto.Changeset.t()}`
- `Relay.Activity.log(%Schemas.Card{}, %{type: atom(), actor: actor, meta: map()}) :: {:ok, %Schemas.Activity{}} | {:error, Ecto.Changeset.t()}`
- `Relay.Activity.list_timeline(%Schemas.Card{}) :: [%Schemas.Comment{} | %Schemas.Activity{}]` (ascending `inserted_at`)
- Private `Relay.Cards.arrival_status/1`: `%Stage{owner: :ai} -> :working`, `%Stage{owner: :human} -> :queued` (reuse, do not duplicate)
- where `actor :: :agent | {:user, user_id :: integer()}`

*Produces (Task 2 relies on these exact shapes):*
- `Schemas.Card` field `blocked_since :: DateTime.t() | nil` (`:utc_datetime`), managed by `Schemas.Card.status_changeset/2`
- `Relay.Cards.request_input(card :: %Schemas.Card{}, question :: String.t(), actor \\ :agent) :: {:ok, %Schemas.Card{}} | {:error, Ecto.Changeset.t()}`
- `Relay.Cards.answer_input(card :: %Schemas.Card{}, answer :: String.t(), actor \\ :agent) :: {:ok, %Schemas.Card{}} | {:error, Ecto.Changeset.t()}`
- `Schemas.Activity` type enum gains `:needs_input` (with `meta: %{"question" => String.t()}`) and `:input_answered` (empty meta)

**Steps**

- [x] Generate the migration with `mix ecto.gen.migration add_blocked_since_to_cards` and fill it in:

  ```elixir
  defmodule Relay.Repo.Migrations.AddBlockedSinceToCards do
    use Ecto.Migration

    def change do
      alter table(:cards) do
        add :blocked_since, :utc_datetime, null: true
      end
    end
  end
  ```

  Run `mix ecto.migrate`.

- [x] Write the failing domain tests. Create `test/relay/cards_needs_input_test.exs` with exactly:

  ```elixir
  defmodule Relay.CardsNeedsInputTest do
    use Relay.DataCase, async: true

    import Ecto.Query

    alias Relay.Activity
    alias Relay.Cards
    alias Schemas.Card
    alias Schemas.Comment

    setup do
      board = insert(:board, key: "RLY")
      ai_stage = insert(:stage, board: board, name: "Code", owner: :ai, position: 1)
      human_stage = insert(:stage, board: board, name: "Check", owner: :human, position: 2)
      %{board: board, ai_stage: ai_stage, human_stage: human_stage}
    end

    describe "request_input/3" do
      test "sets :needs_input, stamps blocked_since, and records the question twice over",
           %{ai_stage: stage} do
        {:ok, card} = Cards.create_card(stage, %{title: "Ship exports"})

        assert {:ok, %Card{} = blocked} = Cards.request_input(card, "Which region?")

        assert blocked.status == :needs_input
        assert %DateTime{} = blocked.blocked_since
        assert DateTime.diff(DateTime.utc_now(), blocked.blocked_since, :second) in 0..5

        timeline = Activity.list_timeline(blocked)

        assert %Comment{actor_type: :agent} =
                 Enum.find(timeline, &match?(%Comment{body: "Which region?"}, &1))

        assert %Schemas.Activity{actor_type: :agent, meta: %{"question" => "Which region?"}} =
                 Enum.find(timeline, &match?(%Schemas.Activity{type: :needs_input}, &1))
      end

      test "attributes the question to a user actor", %{ai_stage: stage} do
        user = insert(:user)
        {:ok, card} = Cards.create_card(stage, %{title: "Human asks"})

        {:ok, blocked} = Cards.request_input(card, "Blue or green?", {:user, user.id})

        entry =
          blocked
          |> Activity.list_timeline()
          |> Enum.find(&match?(%Schemas.Activity{type: :needs_input}, &1))

        assert entry.actor_type == :user
        assert entry.user_id == user.id
      end

      test "asking again keeps the original blocked_since and appends the new question last",
           %{ai_stage: stage} do
        {:ok, card} = Cards.create_card(stage, %{title: "Twice"})
        {:ok, card} = Cards.request_input(card, "First question?")
        first_blocked_since = card.blocked_since

        {:ok, card} = Cards.request_input(card, "Second question?")

        assert card.status == :needs_input
        assert card.blocked_since == first_blocked_since

        questions =
          card
          |> Activity.list_timeline()
          |> Enum.filter(&match?(%Schemas.Activity{type: :needs_input}, &1))
          |> Enum.map(& &1.meta["question"])

        assert questions == ["First question?", "Second question?"]
      end

      test "blocked_since supports querying blocked cards and their age", %{ai_stage: stage} do
        {:ok, blocked} = Cards.create_card(stage, %{title: "Blocked"})
        {:ok, blocked} = Cards.request_input(blocked, "Which region?")
        {:ok, _free} = Cards.create_card(stage, %{title: "Free"})

        blocked_ids = Repo.all(from c in Card, where: not is_nil(c.blocked_since), select: c.id)

        assert blocked_ids == [blocked.id]
        assert DateTime.diff(DateTime.utc_now(), blocked.blocked_since, :second) >= 0
      end
    end

    describe "answer_input/3" do
      test "on an AI-meant stage: resumes :working, clears blocked_since, logs comment + entry",
           %{ai_stage: stage} do
        user = insert(:user)
        {:ok, card} = Cards.create_card(stage, %{title: "Resume"})
        {:ok, card} = Cards.request_input(card, "Which region?")

        assert {:ok, %Card{} = answered} = Cards.answer_input(card, "us-east-1", {:user, user.id})

        assert answered.status == :working
        assert answered.blocked_since == nil

        timeline = Activity.list_timeline(answered)
        answer = Enum.find(timeline, &match?(%Comment{body: "us-east-1"}, &1))
        assert answer.actor_type == :user
        assert answer.user_id == user.id

        entry = Enum.find(timeline, &match?(%Schemas.Activity{type: :input_answered}, &1))
        assert entry.actor_type == :user
        assert entry.user_id == user.id
      end

      test "on a human-meant stage: returns the card to :queued", %{human_stage: stage} do
        {:ok, card} = Cards.create_card(stage, %{title: "Human next"})
        {:ok, card} = Cards.request_input(card, "Ready?")

        assert {:ok, %Card{status: :queued, blocked_since: nil}} =
                 Cards.answer_input(card, "Yes", :agent)
      end
    end

    describe "blocked_since across the other status paths" do
      test "set_status into :needs_input stamps blocked_since without any question entry",
           %{ai_stage: stage} do
        {:ok, card} = Cards.create_card(stage, %{title: "Manual block"})

        {:ok, blocked} = Cards.set_status(card, %{status: :needs_input})

        assert %DateTime{} = blocked.blocked_since

        refute blocked
               |> Activity.list_timeline()
               |> Enum.any?(&match?(%Schemas.Activity{type: :needs_input}, &1))
      end

      test "set_status out of :needs_input clears blocked_since", %{ai_stage: stage} do
        {:ok, card} = Cards.create_card(stage, %{title: "Unblock"})
        {:ok, blocked} = Cards.set_status(card, %{status: :needs_input})

        {:ok, unblocked} = Cards.set_status(blocked, %{status: :in_review})

        assert unblocked.blocked_since == nil
      end

      test "a progress-only update while blocked keeps blocked_since", %{ai_stage: stage} do
        {:ok, card} = Cards.create_card(stage, %{title: "Hold"})
        {:ok, blocked} = Cards.set_status(card, %{status: :needs_input})

        {:ok, still_blocked} = Cards.set_status(blocked, %{status: :needs_input, progress: 40})

        assert still_blocked.blocked_since == blocked.blocked_since
      end

      test "approve out of :needs_input clears blocked_since", %{board: board} do
        gate = insert(:stage, board: board, name: "Gate", position: 3, owner: :human, approval_gate: true)
        next = insert(:stage, board: board, name: "Deploy", position: 4, owner: :ai)
        {:ok, card} = Cards.create_card(gate, %{title: "Gated"})
        {:ok, blocked} = Cards.request_input(card, "Approve the config?")

        {:ok, approved} = Cards.approve(blocked)

        assert approved.stage_id == next.id
        assert approved.status == :working
        assert approved.blocked_since == nil
      end
    end
  end
  ```

- [x] Append two broadcast tests inside the existing `describe "Cards broadcasts"` block of
  `test/relay/context_broadcasts_test.exs` (its setup already subscribes to the board topic
  and provides `user` and `spec` — a human-owned default stage):

  ```elixir
  test "request_input broadcasts the blocked card and both timeline entries", %{spec: spec} do
    {:ok, %Card{id: card_id} = card} = Cards.create_card(spec, %{title: "Blocked"})

    {:ok, _blocked} = Cards.request_input(card, "Which region?")

    assert_receive {:card_upserted, %Card{id: ^card_id, status: :needs_input, blocked_since: %DateTime{}}}
    assert_receive {:timeline_appended, ^card_id, %Schemas.Comment{body: "Which region?"}}

    assert_receive {:timeline_appended, ^card_id,
                    %Schemas.Activity{type: :needs_input, meta: %{"question" => "Which region?"}}}
  end

  test "answer_input broadcasts the resumed card and the answer", %{user: user, spec: spec} do
    {:ok, %Card{id: card_id} = card} = Cards.create_card(spec, %{title: "Answer me"})
    {:ok, blocked} = Cards.request_input(card, "Ready?")

    {:ok, _answered} = Cards.answer_input(blocked, "Yes — go ahead", {:user, user.id})

    assert_receive {:card_upserted, %Card{id: ^card_id, status: :queued, blocked_since: nil}}
    assert_receive {:timeline_appended, ^card_id, %Schemas.Comment{body: "Yes — go ahead"}}
    assert_receive {:timeline_appended, ^card_id, %Schemas.Activity{type: :input_answered}}
  end
  ```

- [x] Append the API round-trip tests to `test/relay_web/api/card_actions_test.exs` (its
  setup provides `conn` with a bearer token, `board`, `spec` (human stage), and `code` (AI
  stage); the existing `"needs-input sets status and records the question"` test must keep
  passing unchanged — the refactor is behaviour-preserving):

  ```elixir
  test "needs-input records the durable :needs_input activity and stamps blocked_since", %{
    conn: conn,
    board: board,
    spec: spec
  } do
    card = insert(:card, stage: spec)

    body =
      conn
      |> post(~p"/api/cards/#{ref(board, card)}/needs-input", %{question: "Blue or green?"})
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.any?(
             body["timeline"],
             &(&1["kind"] == "activity" and &1["type"] == "needs_input" and
                 &1["meta"]["question"] == "Blue or green?")
           )

    reloaded = Cards.get_card_by_ref(board, ref(board, card))
    assert reloaded.status == :needs_input
    assert %DateTime{} = reloaded.blocked_since
  end

  test "the human's answer reaches the agent via the card timeline", %{
    conn: conn,
    board: board,
    code: code
  } do
    card = insert(:card, stage: code)
    {:ok, blocked} = Cards.request_input(card, "Which region?")
    {:ok, _answered} = Cards.answer_input(blocked, "us-east-1", {:user, board.owner_id})

    body =
      conn
      |> get(~p"/api/cards/#{ref(board, card)}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["status"] == "working"
    assert Enum.any?(body["timeline"], &(&1["kind"] == "comment" and &1["body"] == "us-east-1"))
    assert Enum.any?(body["timeline"], &(&1["kind"] == "activity" and &1["type"] == "input_answered"))
  end

  test "needs-input with a non-string question is invalid", %{conn: conn, board: board, spec: spec} do
    card = insert(:card, stage: spec)

    assert conn
           |> post(~p"/api/cards/#{ref(board, card)}/needs-input", %{question: 42})
           |> json_response(400)
  end
  ```

- [x] Run `mix test test/relay/cards_needs_input_test.exs test/relay/context_broadcasts_test.exs test/relay_web/api/card_actions_test.exs`
  — expect failures (`Cards.request_input` undefined, unknown `blocked_since` field, invalid
  activity types).

- [x] Implement the schema changes. In `lib/schemas/card.ex`: add the field below `progress`
  inside the `schema` block —

  ```elixir
      field :blocked_since, :utc_datetime
  ```

  — and extend `status_changeset/2` (update its `@doc` to mention the `blocked_since`
  bookkeeping):

  ```elixir
    def status_changeset(card, attrs) do
      card
      |> cast(attrs, [:status, :progress])
      |> validate_required([:status])
      |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
      |> manage_blocked_since()
    end

    # `blocked_since` tracks how long the card has been waiting on a human
    # (MMF 14): stamped when the status *changes to* :needs_input, cleared
    # when it changes to anything else, untouched when the status isn't
    # changing (e.g. a progress-only update while blocked). Every status
    # path — drawer control, API, approve/reject, request/answer — goes
    # through this changeset, so the invariant holds everywhere. Never cast
    # from user input.
    defp manage_blocked_since(changeset) do
      case fetch_change(changeset, :status) do
        {:ok, :needs_input} ->
          put_change(changeset, :blocked_since, DateTime.truncate(DateTime.utc_now(), :second))

        {:ok, _other} ->
          put_change(changeset, :blocked_since, nil)

        :error ->
          changeset
      end
    end
  ```

  In `lib/schemas/activity.ex`: extend the type list —

  ```elixir
    @types [
      :created,
      :moved,
      :status_changed,
      :owners_changed,
      :commented,
      :approved,
      :rejected,
      :needs_input,
      :input_answered
    ]
  ```

  — and mention the two new types in the moduledoc (`:needs_input` carries
  `meta: %{"question" => …}`; `:input_answered` marks the human's answer, MMF 14). Also
  extend the enumerated type list in `Relay.Activity.log/2`'s `@doc` in
  `lib/relay/activity.ex`.

- [x] Implement the context functions in `lib/relay/cards.ex`, placed directly after
  `reject/3` (they mirror the approve/reject `with`-chain style; the shared
  `set_status`/`add_comment`/`log` calls emit all MMF 18 broadcasts — add no new
  `Events.broadcast` calls):

  ```elixir
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
  ```

  Also add one sentence to `set_status/3`'s `@doc`: entering `:needs_input` stamps
  `blocked_since` and leaving it clears it (managed in `Schemas.Card.status_changeset/2`).

- [x] Refactor the API endpoint. In `lib/relay_web/controllers/api/card_controller.ex`,
  replace the first `needs_input/2` clause with the following (the
  `def needs_input(_conn, %{"ref" => _ref}), do: {:error, :invalid_request}` fallback stays;
  non-binary questions now fall through to it → 400):

  ```elixir
    def needs_input(conn, %{"ref" => ref, "question" => question}) when is_binary(question) do
      board = conn.assigns.current_board

      with %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref),
           {:ok, card} <- Cards.request_input(card, question, :agent) do
        render(conn, :show, board: board, card: card, timeline: Activity.list_timeline(card))
      else
        nil -> {:error, :not_found}
        {:error, changeset} -> {:error, changeset}
      end
    end
  ```

- [x] Run the three test files again — expect all green. Then run `mix precommit` and fix
  anything it flags.
- [ ] Commit.

**Deliverable:** the full question ↔ answer round trip works headlessly — an agent blocks a
card with a question via the API (status `:needs_input`, `blocked_since` stamped, question
comment + durable `:needs_input` activity entry), any caller answers via
`Cards.answer_input/3` (answer comment + `:input_answered` entry, status `:working`/`:queued`
by stage owner, `blocked_since` cleared), every transition broadcasts, and the agent reads the
answer back from `GET /api/cards/:ref`. Blocked cards are queryable by `blocked_since`, and
every status path out of `:needs_input` (status control, approve) clears it.

**Commit message:** `feat(cards): needs-input question/answer domain (MMF 14) — blocked_since + request_input/answer_input`

---

### Task 2: Drawer question panel + answer composer

**Files**
- Modify: `lib/relay_web/components/core_components.ex` (`card_drawer/1` panel,
  `waiting_label/1`, two `activity_phrase/1` clauses), `lib/relay_web/live/board_live.ex`,
  `storybook/core_components/card_drawer.story.exs`
- Test (create): `test/relay_web/live/board_live_needs_input_test.exs`

**Interfaces**

*Consumes (from Task 1):*
- `Relay.Cards.request_input(card, question :: String.t(), actor \\ :agent) :: {:ok, %Schemas.Card{}} | {:error, Ecto.Changeset.t()}`
- `Relay.Cards.answer_input(card, answer :: String.t(), actor \\ :agent) :: {:ok, %Schemas.Card{}} | {:error, Ecto.Changeset.t()}`
- `Schemas.Card.blocked_since :: DateTime.t() | nil`
- `%Schemas.Activity{type: :needs_input, meta: %{"question" => String.t()}}` and
  `%Schemas.Activity{type: :input_answered}` timeline entries
- Existing: `Relay.Activity.list_timeline/1`, BoardLive's `current_actor/1`
  (`{:user, user_id}`), `refresh_card/2`, `assign_selected_card/2`, `maybe_refresh_drawer/2`,
  `empty_comment_form/0` pattern.

*Produces:*
- `card_drawer/1` new optional attrs: `question :: String.t() | nil` (default `nil`) and
  `answer_form` (a `Phoenix.HTML.Form` for `answer[body]`; required whenever
  `card.status == :needs_input`). New DOM ids: `#needs-input-panel`, `#needs-input-question`,
  `#needs-input-waiting`, `#needs-input-form`, `#needs-input-answer`, `#needs-input-send`.
- BoardLive event `"answer_input"` (form params `answer[body]`), assigns `@question` and
  `@answer_form`.

**Mockup fidelity** (`docs/designs/Relay Board.dc.html`, drawer blocked panel, lines ~398–405 —
copy these values exactly):
- Panel: `background:oklch(0.975 0.025 75); border:1px solid oklch(0.87 0.07 75);`
  border-radius 10px, padding 14px, column flex with 11px gap.
- Label: mono 10px semibold, letter-spacing 0.05em, color `oklch(0.52 0.11 65)`, copy
  `RELAY AI NEEDS YOUR INPUT`.
- Question: 13.5px, line-height 1.5, color `oklch(0.33 0.03 65)`.
- Textarea: 3 rows, border `1px solid oklch(0.86 0.05 75)`, radius 7px, white background,
  13px text, placeholder `Type your answer — the AI picks up where it left off…`.
- Button: `background:oklch(0.70 0.13 65)`, white text, radius 7px, 13px semibold, copy
  `Send to AI →`, aligned to flex start.
- The board card's amber NEEDS INPUT treatment (mockup lines ~127–130) shipped in MMF 06
  (`board_card/1`'s `.card-needs-input` block + `border-l-warning` accent) — do NOT touch it.

**Steps**

- [ ] Write the failing LiveView tests. Create
  `test/relay_web/live/board_live_needs_input_test.exs` with exactly:

  ```elixir
  defmodule RelayWeb.BoardLiveNeedsInputTest do
    use RelayWeb.ConnCase, async: true

    import Phoenix.LiveViewTest

    alias Relay.Activity
    alias Relay.Boards
    alias Relay.Cards
    alias Schemas.Comment

    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
      code = Enum.find(board.stages, &(&1.name == "Code"))
      %{board: board, backlog: backlog, code: code}
    end

    test "no panel renders for a card that does not need input", %{conn: conn, backlog: backlog} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Calm card"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer")
      refute has_element?(view, "#needs-input-panel")
    end

    test "a blocked card's drawer shows the amber panel with the latest question and composer",
         %{conn: conn, code: code} do
      {:ok, card} = Cards.create_card(code, %{title: "Ship exports"})
      {:ok, _blocked} = Cards.request_input(card, "Billing timezone or the viewer's?")

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#needs-input-panel", "RELAY AI NEEDS YOUR INPUT")
      assert has_element?(view, "#needs-input-question", "Billing timezone or the viewer's?")
      assert has_element?(view, "#needs-input-waiting", "waiting")
      assert has_element?(view, "#needs-input-answer")
      assert has_element?(view, "#needs-input-send", "Send to AI")
      assert has_element?(view, "#card-drawer-timeline .timeline-activity-phrase", "asked for input")
    end

    test "re-asking shows the newest question, not the old one", %{conn: conn, code: code} do
      {:ok, card} = Cards.create_card(code, %{title: "Twice"})
      {:ok, card} = Cards.request_input(card, "First question?")
      {:ok, _card} = Cards.request_input(card, "Second question?")

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#needs-input-question", "Second question?")
      refute has_element?(view, "#needs-input-question", "First question?")
    end

    test "answering resumes an AI-stage card to :working, logs, and hides the panel",
         %{conn: conn, board: board, code: code} do
      {:ok, card} = Cards.create_card(code, %{title: "Ship exports"})
      {:ok, _blocked} = Cards.request_input(card, "Which bucket?")

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")
      assert has_element?(view, "#stage-col-#{code.position}-cards .card-needs-input", "NEEDS INPUT")

      view
      |> form("#needs-input-form", answer: %{body: "The relay-exports bucket"})
      |> render_submit()

      refute has_element?(view, "#needs-input-panel")
      assert has_element?(view, "#card-drawer-timeline .timeline-comment-body", "The relay-exports bucket")
      assert has_element?(view, "#card-drawer-timeline .timeline-activity-phrase", "answered the question")
      refute has_element?(view, "#stage-col-#{code.position}-cards .card-needs-input")

      reloaded = Cards.get_card_by_ref(board, "RLY-1")
      assert reloaded.status == :working
      assert reloaded.blocked_since == nil

      answer =
        reloaded
        |> Activity.list_timeline()
        |> Enum.find(&match?(%Comment{body: "The relay-exports bucket"}, &1))

      assert answer.actor_type == :user
    end

    test "answering a human-stage card returns it to :queued",
         %{conn: conn, board: board, backlog: backlog} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Human next"})
      {:ok, _blocked} = Cards.request_input(card, "Ready to start?")

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> form("#needs-input-form", answer: %{body: "Yes, go"}) |> render_submit()

      refute has_element?(view, "#needs-input-panel")
      assert Cards.get_card_by_ref(board, "RLY-1").status == :queued
    end

    test "a human-blocked card (status control, no question) still gets the composer",
         %{conn: conn, backlog: backlog} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Manual block"})
      {:ok, _blocked} = Cards.set_status(card, %{status: :needs_input})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#needs-input-panel")
      refute has_element?(view, "#needs-input-question")
      assert has_element?(view, "#needs-input-answer")
    end

    test "a blank answer is a no-op that keeps the panel", %{conn: conn, board: board, code: code} do
      {:ok, card} = Cards.create_card(code, %{title: "Still blocked"})
      {:ok, _blocked} = Cards.request_input(card, "Which bucket?")

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> form("#needs-input-form", answer: %{body: ""}) |> render_submit()

      assert has_element?(view, "#needs-input-panel")
      assert Cards.get_card_by_ref(board, "RLY-1").status == :needs_input
    end

    test "a request_input from elsewhere pops the panel into an open drawer live (MMF 18)",
         %{conn: conn, code: code} do
      {:ok, card} = Cards.create_card(code, %{title: "Live block"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")
      refute has_element?(view, "#needs-input-panel")

      {:ok, _blocked} = Cards.request_input(card, "Which region?")

      assert has_element?(view, "#needs-input-panel", "Which region?")
    end
  end
  ```

- [ ] Run `mix test test/relay_web/live/board_live_needs_input_test.exs` — expect failures
  (no `#needs-input-panel`, unknown `question`/`answer_form` assigns, `FunctionClauseError`
  from `activity_phrase/1` on the new entry types).

- [ ] Implement the component. In `lib/relay_web/components/core_components.ex`:

  1. Add the two attrs after the `comment_form` attr of `card_drawer/1` (and extend the
     `card` attr's `doc` to mention `blocked_since`; extend the component `@doc`'s events
     list with `"answer_input"` — form params `answer[body]`):

  ```elixir
    attr :question, :string,
      default: nil,
      doc: "the latest :needs_input question from the timeline; nil when a human blocked without one"

    attr :answer_form, :any,
      default: nil,
      doc: "a Phoenix.HTML.Form for answer[body]; required when the card's status is :needs_input"
  ```

  2. Insert the panel between `</header>` and the Description `<section>` in the template
     (the spec places it above the description; inline oklch values are the mockup's):

  ```heex
            <section
              :if={@card.status == :needs_input}
              id="needs-input-panel"
              class="flex flex-col gap-[11px] rounded-[10px] p-3.5"
              style="background:oklch(0.975 0.025 75);border:1px solid oklch(0.87 0.07 75);"
            >
              <div class="flex items-center justify-between">
                <span
                  class="font-mono text-[10px] font-semibold tracking-[0.05em]"
                  style="color:oklch(0.52 0.11 65);"
                >
                  RELAY AI NEEDS YOUR INPUT
                </span>
                <span
                  :if={@card.blocked_since}
                  id="needs-input-waiting"
                  class="font-mono text-[10px]"
                  style="color:oklch(0.52 0.11 65);"
                >
                  {waiting_label(@card.blocked_since)}
                </span>
              </div>
              <p
                :if={@question}
                id="needs-input-question"
                class="text-[13.5px] leading-normal"
                style="color:oklch(0.33 0.03 65);"
              >
                {@question}
              </p>
              <.form
                for={@answer_form}
                id="needs-input-form"
                class="flex flex-col items-start gap-[11px]"
                phx-submit="answer_input"
              >
                <.input
                  field={@answer_form[:body]}
                  type="textarea"
                  id="needs-input-answer"
                  rows="3"
                  placeholder="Type your answer — the AI picks up where it left off…"
                  class="w-full resize-none rounded-[7px] bg-white p-[9px] text-[13px] leading-snug"
                  style="border:1px solid oklch(0.86 0.05 75);color:oklch(0.30 0.02 255);"
                />
                <button
                  id="needs-input-send"
                  type="submit"
                  class="btn btn-sm rounded-[7px] border-none font-semibold text-white"
                  style="background:oklch(0.70 0.13 65);"
                >
                  Send to AI →
                </button>
              </.form>
            </section>
  ```

  3. Add the aging-hint helper next to the other drawer privates (e.g. after
     `paused_owner?/2`):

  ```elixir
    # The panel's aging hint ("waiting 3h"), derived from Card.blocked_since —
    # the mockup's small amber mono text beside the panel label.
    defp waiting_label(%DateTime{} = blocked_since) do
      minutes = max(DateTime.diff(DateTime.utc_now(), blocked_since, :minute), 0)

      cond do
        minutes < 60 -> "waiting #{minutes}m"
        minutes < 1440 -> "waiting #{div(minutes, 60)}h"
        true -> "waiting #{div(minutes, 1440)}d"
      end
    end
  ```

  4. Add the two timeline phrases after the `:commented` clause of `activity_phrase/1`
     (without them the drawer timeline raises `FunctionClauseError` on the new entry types):

  ```elixir
    defp activity_phrase(%Activity{type: :needs_input}), do: "asked for input"

    defp activity_phrase(%Activity{type: :input_answered}), do: "answered the question"
  ```

- [ ] Implement the LiveView side. In `lib/relay_web/live/board_live.ex`:

  1. Pass the new attrs in `render/1`'s `<.card_drawer …>` call (after `comment_form`):

  ```heex
        question={@question}
        answer_form={@answer_form}
  ```

  2. Add the event handler directly after the `"post_comment"` fallback clause
     (`def handle_event("post_comment", _params, socket), do: {:noreply, socket}`); a failed
     answer (blank body → the comment changeset errors) is a silent no-op — the panel simply
     stays:

  ```elixir
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
  ```

  3. Replace `refresh_card/2` so every drawer refresh (local actions AND broadcast-applied
     remote changes via `maybe_refresh_drawer/2`) recomputes the question from one timeline
     fetch and resets the composer:

  ```elixir
    # A persisted baton change: sync the drawer assigns and re-stream the
    # card so the board card re-renders its colour/badge. Also recomputes
    # the needs-input panel's question from the fresh timeline (MMF 14).
    defp refresh_card(socket, %Card{} = card) do
      timeline = Activity.list_timeline(card)

      socket
      |> assign(:selected_card, card)
      |> assign(:status_form, status_form(card))
      |> assign(:question, latest_question(card, timeline))
      |> assign(:answer_form, empty_answer_form())
      |> stream(:timeline, timeline, reset: true)
      |> stream_insert(stream_name(card.stage_id), card)
    end
  ```

  4. In `assign_selected_card/2`, bind the timeline once and assign the new state. The
     `%Card{}` branch becomes:

  ```elixir
      %Card{} = card ->
        timeline = Activity.list_timeline(card)

        socket
        |> assign(:selected_card, card)
        |> assign(:selected_stage, find_stage_by_id(socket, card.stage_id))
        |> assign(:title_form, to_form(%{"title" => card.title}, as: :card))
        |> assign(:editing_description, false)
        |> assign(:description_form, nil)
        |> assign(:status_form, status_form(card))
        |> assign(:comment_form, empty_comment_form())
        |> assign(:question, latest_question(card, timeline))
        |> assign(:answer_form, empty_answer_form())
        |> stream(:timeline, timeline, reset: true)
  ```

  and the `nil` branch's `assign` keyword list gains `question: nil, answer_form: nil`.

  5. Add the helpers next to `empty_comment_form/0`:

  ```elixir
    defp empty_answer_form, do: to_form(%{"body" => ""}, as: :answer)

    # The panel shows the newest :needs_input question. A human-blocked card
    # (status control — no question recorded) yields nil, and the panel
    # renders with just the composer (spec edge case).
    defp latest_question(%Card{status: :needs_input}, timeline) do
      timeline
      |> Enum.reverse()
      |> Enum.find_value(fn
        %Schemas.Activity{type: :needs_input, meta: meta} -> meta["question"]
        _entry -> nil
      end)
    end

    defp latest_question(_card, _timeline), do: nil
  ```

- [ ] Run `mix test test/relay_web/live/board_live_needs_input_test.exs` — expect green.
  Also run `mix test test/relay_web/live test/relay_web/components` to confirm no existing
  drawer/realtime test regressed.

- [ ] Refresh the storybook story `storybook/core_components/card_drawer.story.exs`: add
  `blocked_since: nil` to the `story_card/0` map (after `progress: 61`), then add a third
  variation after `:editing_description`:

  ```elixir
        %Variation{
          id: :needs_input,
          attributes: %{
            id: "story-drawer-3",
            ref: "RLY-9",
            card: %{
              story_card()
              | status: :needs_input,
                progress: nil,
                blocked_since: DateTime.add(DateTime.utc_now(), -3, :hour)
            },
            stage_name: "Code",
            stage_owner: :ai,
            active_owner: :ai,
            current_user_id: 1,
            close_patch: "/storybook/core_components/card_drawer",
            title_form: Phoenix.Component.to_form(%{"title" => "Draft the onboarding spec"}, as: :card),
            status_form: Phoenix.Component.to_form(%{"status" => "needs_input", "progress" => nil}, as: :card),
            question: "Should exports use the billing timezone or the viewer's local timezone?",
            answer_form: Phoenix.Component.to_form(%{"body" => ""}, as: :answer),
            timeline: story_timeline(),
            comment_form: Phoenix.Component.to_form(%{"body" => ""}, as: :comment)
          }
        }
  ```

- [ ] Run `mix precommit` and fix anything it flags.
- [ ] Commit.

**Deliverable:** opening a `:needs_input` card's drawer shows the mockup's amber
"RELAY AI NEEDS YOUR INPUT" panel with the latest question, a "waiting Xm/Xh/Xd" aging hint
from `blocked_since`, and the answer composer; submitting "Send to AI →" logs the answer as
the signed-in user, flips the card to `:working`/`:queued`, clears the block, hides the
panel, drops the board card's amber badge (live in every session via MMF 18), and the
exchange reads back in the timeline and the API. Human-blocked cards (no question) get the
composer with an empty question area. Storybook's card_drawer page gains the blocked
variation (`/storybook/core_components/card_drawer`).

**Commit message:** `feat(board): drawer needs-input question panel + answer composer (MMF 14)`
