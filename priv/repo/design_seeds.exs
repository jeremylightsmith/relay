# Seeds the "Design Capture" board — one card per *card-detail* state, so
# `bin/design-capture.mjs` can shoot every face of the card drawer from the
# real LiveView and emit `docs/designs-as-is/Relay Card Detail.dc.html`.
#
#     mix run priv/repo/design_seeds.exs
#
# Idempotent: the design-capture board is deleted (owner-scoped, by slug) and
# rebuilt, so re-running never piles up cards.
#
# This is the *card detail* counterpart to `run_demo_seeds.exs` (which seeds
# run-panel states on its own board). Card refs are stable because refs are
# assigned in creation order — `bin/design-capture.mjs` addresses cards by ref,
# so KEEP THE CREATION ORDER BELOW STABLE when you add states; append new cards
# at the end rather than inserting in the middle.
import Ecto.Query

alias Ecto.Changeset
alias Relay.Accounts
alias Relay.Activity
alias Relay.Boards
alias Relay.Cards
alias Relay.Flows
alias Relay.Members
alias Relay.Repo
alias Schemas.Board
alias Schemas.CardRejection
alias Schemas.Comment
alias Schemas.NodeExecution
alias Schemas.Run
alias Schemas.User

now = DateTime.truncate(DateTime.utc_now(), :second)
minutes_ago = fn m -> DateTime.add(now, -m * 60, :second) end

email = "jeremy.lightsmith@gmail.com"

user =
  case Repo.get_by(User, email: email) do
    nil ->
      %User{provider: "seed", provider_uid: "seed-" <> email}
      |> User.changeset(%{email: email, name: "Jeremy Lightsmith"})
      |> Repo.insert!()

    %User{} = existing ->
      existing
  end

Repo.delete_all(from b in Board, where: b.owner_id == ^user.id and b.slug == "design-capture")

{:ok, board} = Boards.create_board(user, %{name: "Design Capture"})

board =
  case board |> Changeset.change(slug: "design-capture") |> Repo.update() do
    {:ok, updated} ->
      updated

    {:error, _changeset} ->
      IO.puts(~s(Could not force slug "design-capture" — using #{board.slug} instead.))
      board
  end

board = Repo.preload(board, :stages)

# /dev/login mints a fixed dev@relay.local user, distinct from the seed owner —
# add it as a member so the board is reachable from the capture script.
dev_user = Accounts.ensure_dev_user!()

case Members.invite(board, dev_user.email) do
  {:ok, _membership} -> :ok
  {:error, :already_member} -> :ok
end

stage = fn name -> Enum.find(board.stages, &(&1.name == name)) || hd(board.stages) end

{:ok, code_flow} = board |> Flows.get_flow!("code") |> Flows.enable_flow()
{:ok, spec_flow} = board |> Flows.get_flow!("spec") |> Flows.enable_flow()
flows_by_key = %{code_flow.key => code_flow, spec_flow.key => spec_flow}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

new_card = fn stage_name, attrs ->
  {:ok, card} = Cards.create_card(stage.(stage_name), Map.take(attrs, [:title]))
  {:ok, card} = Cards.update_card(card, Map.drop(attrs, [:title]))
  card
end

ai = fn card ->
  {:ok, card} = Cards.assign_ai(card)
  card
end

mine = fn card ->
  {:ok, card} = Cards.set_owners(card, [{:user, user.id}], {:user, user.id})
  card
end

status = fn card, s ->
  {:ok, card} = Cards.set_status(card, %{status: s})
  card
end

sub_tasks = fn card, list ->
  {:ok, card} = Cards.set_sub_tasks(card, Enum.map(list, fn {title, done} -> %{title: title, done: done} end))
  card
end

say = fn card, actor_type, kind, body, minutes ->
  %Comment{
    card_id: card.id,
    actor_type: actor_type,
    user_id: if(actor_type == :user, do: user.id),
    kind: kind,
    inserted_at: minutes_ago.(minutes),
    updated_at: minutes_ago.(minutes)
  }
  |> Comment.changeset(%{body: body})
  |> Repo.insert!()

  card
end

add_run = fn card, attrs ->
  defaults = %{card_id: card.id, flow_key: "code", status: :running, started_at: minutes_ago.(10)}
  merged = Map.merge(defaults, attrs)
  flow = Map.fetch!(flows_by_key, merged.flow_key)
  Repo.insert!(struct!(Run, Map.put(merged, :flow_id, flow.id)))
end

# `node:`/`duration_s:` are this script's shorthand — see run_demo_seeds.exs.
add_ne = fn run, attrs ->
  {node, attrs} = Map.pop(attrs, :node)
  {duration_s, attrs} = Map.pop(attrs, :duration_s, 42)
  {started_at, attrs} = Map.pop(attrs, :started_at, minutes_ago.(1))

  defaults = %{
    run_id: run.id,
    node_key: node,
    visit: 1,
    attempt: 1,
    outcome: :succeeded,
    started_at: started_at,
    finished_at: duration_s && DateTime.add(started_at, duration_s, :second)
  }

  Repo.insert!(struct!(NodeExecution, Map.merge(defaults, attrs)))
end

cost = fn s -> Decimal.new(s) end

# ---------------------------------------------------------------------------
# shared copy — long enough that the drawer's prose blocks show real rhythm
# ---------------------------------------------------------------------------

description = """
Board owners keep asking for their data outside Relay — for a standup deck, a
quarterly review, a spreadsheet of cycle times. Today the only way out is the
API, which is a non-starter for anyone who isn't a developer.

Add a **Export CSV** action to the board menu that streams every visible card
with its stage, owner, status, tag, and age in days.
"""

acceptance = """
- Board menu shows **Export CSV**; it is hidden for members without read access.
- The download starts within 2s on a 5,000-card board and never buffers the
  whole board in memory.
- Columns: ref, title, stage, substage, owner, status, tag, age_days, updated_at.
- Archived cards are excluded unless `?archived=1` is passed.
- The filename is `<board-slug>-YYYY-MM-DD.csv`.
"""

spec = """
`Relay.Exports.stream_board_csv/2` returns a `Stream` of iodata rows, built on
`Repo.stream/2` inside a transaction so the row cursor stays open.

The controller wraps it in `Plug.Conn.send_chunked/2` and writes each row as it
arrives. No context reaches into the web layer; the controller owns the
`content-disposition` header and nothing else.

Ordering matches the board: stage position, then card position, so the CSV reads
top-to-bottom the same way the board does.
"""

plan = """
## Task 1 — `Relay.Exports.stream_board_csv/2`
Pure function over a preloaded board. Tests cover column order, archived
filtering, and that the stream is lazy (assert `Repo.stream` is used inside a
transaction).

## Task 2 — `RelayWeb.ExportController`
`GET /boards/:slug/export.csv`. Scope-checked, chunked response, filename
header. Tests cover the 403 for a non-member and the chunk boundaries.

## Task 3 — board menu entry
Add the menu item behind the same scope check. LiveView test asserts the link
renders for a member and not for a stranger.
"""

qr_detail = """
test/relay/export_test.exs:24
  Asserts on %Board{} private struct internals
  (row.__meta__, column ordering). Brittle — assert
  on the CSV bytes the user downloads instead.

→ returned outcome=failed, routed to implement
"""

escalation_detail = """
✗ commit guard: the working tree is dirty after `mix precommit`

  M lib/relay/exports.ex
  M test/relay/exports_test.exs

  mix format rewrote two files the implementer already committed, so the
  node ends with uncommitted changes and cannot hand the branch on.

→ returned outcome=failed, retry budget spent, routed to needs_input
"""

# ---------------------------------------------------------------------------
# 1 · Ready, human-owned — the plain reading state: every prose block filled in.
# ---------------------------------------------------------------------------
ready =
  new_card.("Next up", %{
    title: "Export the board as CSV",
    tag: "reporting",
    description: description,
    acceptance_criteria: acceptance,
    spec: spec
  })

ready = mine.(ready)
ready = say.(ready, :user, :comment, "Finance wants this before the quarter closes — pulling it up.", 220)

ready =
  say.(
    ready,
    :agent,
    :comment,
    "Noted. The streaming approach in the spec is the one that survives a 5k-card board; " <>
      "the buffered version blew past 400MB in a spike.",
    180
  )

_ready = say.(ready, :user, :comment, "Agreed. Ship the streaming one.", 175)

# ---------------------------------------------------------------------------
# 2 · Working — AI holds the baton, sub-task checklist mid-progress.
# ---------------------------------------------------------------------------
working =
  new_card.("Code", %{
    title: "Stream the CSV row by row",
    tag: "reporting",
    description: description,
    acceptance_criteria: acceptance,
    spec: spec,
    plan: plan,
    branch: "RLY-341-stream-csv"
  })

working = ai.(working)
working = status.(working, :working)

working =
  sub_tasks.(working, [
    {"Relay.Exports.stream_board_csv/2 + tests", true},
    {"Chunked ExportController + scope check", true},
    {"Board menu entry behind the read check", false},
    {"Docs: architecture page for the export endpoint", false}
  ])

run = add_run.(working, %{current_node: "implement", started_at: minutes_ago.(14)})
add_ne.(run, %{node: "branch", duration_s: 8, cost: cost.("0.00")})
add_ne.(run, %{node: "implement", duration_s: 160, cost: cost.("0.90")})
add_ne.(run, %{node: "spec_review", duration_s: 31, cost: cost.("0.20")})
add_ne.(run, %{node: "quality_review", outcome: :failed, duration_s: 48, cost: cost.("0.35"), detail: qr_detail})
add_ne.(run, %{node: "implement", attempt: 2, outcome: nil, duration_s: nil, cost: nil})

# ---------------------------------------------------------------------------
# 3 · Needs input · question (A1) — the structured answer stepper.
# ---------------------------------------------------------------------------
question = new_card.("Spec", %{title: "Board search", tag: "search", description: description})
question = ai.(question)

{:ok, question} =
  Cards.request_input(
    question,
    [
      %{
        "prompt" =>
          "Should board search cover card bodies and comments, or just titles? " <>
            "Full-text means a search index and a migration; titles-only ships today.",
        "options" => ["Full-text: bodies + comments", "Titles only for now"],
        "allow_text" => true
      },
      %{
        "prompt" => "Should archived cards match?",
        "options" => ["Yes", "No"],
        "allow_text" => false
      }
    ],
    :agent
  )

run =
  add_run.(question, %{
    flow_key: "spec",
    status: :parked,
    parked_reason: :needs_input,
    current_node: "brainstorm",
    started_at: minutes_ago.(12)
  })

add_ne.(run, %{node: "brainstorm", outcome: :needs_input, duration_s: 190, cost: cost.("0.15")})

# ---------------------------------------------------------------------------
# 4 · Needs input · escalation (A4) — the agent burned its retries and stopped.
# ---------------------------------------------------------------------------
escalated =
  new_card.("Code", %{
    title: "Export cycle-time history",
    tag: "reporting",
    description: description,
    spec: spec,
    branch: "RLY-344-cycle-time-export"
  })

escalated = ai.(escalated)
{:ok, escalated} = Cards.request_input(escalated, escalation_detail, :agent)

run =
  add_run.(escalated, %{
    status: :parked,
    parked_reason: :needs_input,
    current_node: "implement",
    started_at: minutes_ago.(26)
  })

add_ne.(run, %{node: "branch", duration_s: 8, cost: cost.("0.00")})

for {attempt, duration, spend} <- [{1, 210, "1.05"}, {2, 190, "0.98"}, {3, 205, "1.02"}] do
  add_ne.(run, %{
    node: "implement",
    attempt: attempt,
    outcome: :failed,
    duration_s: duration,
    cost: cost.(spend),
    detail: escalation_detail
  })
end

# ---------------------------------------------------------------------------
# 5 · In review — the human review gate, with the AI's result to judge.
# ---------------------------------------------------------------------------
review =
  new_card.("Review", %{
    title: "Card drawer keyboard shortcuts",
    tag: "ux",
    description: """
    Power users live in the drawer. `j`/`k` should walk cards, `e` should focus
    the title, and `esc` should close — without stealing keys from the comment
    box.
    """,
    acceptance_criteria: """
    - `j` / `k` move to the next / previous card in the same stage.
    - `e` focuses the title input; `esc` closes the drawer.
    - No shortcut fires while a text input or textarea has focus.
    """,
    spec: spec,
    plan: plan,
    branch: "RLY-338-drawer-shortcuts",
    pr_url: "https://github.com/relay/relay/pull/338"
  })

review = ai.(review)
review = status.(review, :in_review)

review =
  sub_tasks.(review, [
    {"ArrowKeyGuard hook + focus rules", true},
    {"j/k stage-neighbour navigation", true},
    {"esc closes, respecting open forms", true}
  ])

{:ok, review} =
  Cards.update_ai_result(review, %{
    "summary" =>
      "Added an ArrowKeyGuard hook that owns drawer keybindings and bails out whenever " <>
        "the event target is an input, textarea, or contenteditable. j/k patch to the " <>
        "stage neighbour, e focuses the title, esc closes.",
    "changes" => [
      "assets/js/hooks/arrow_key_guard.js — new hook, 61 lines",
      "lib/relay_web/components/core_components.ex — wire the hook, prev/next refs",
      "lib/relay_web/live/board_live.ex — stage_neighbors/2 assigns",
      "test/relay_web/live/board_live_test.exs — 6 new tests"
    ],
    "screens" => [
      %{"caption" => "Drawer with the shortcut hint row"},
      %{"caption" => "Focus trapped in the comment box — no shortcut fires"}
    ],
    "deploy_url" => "https://relay-pr-338.fly.dev"
  })

review = say.(review, :agent, :comment, "Branch is green: `mix precommit` passes, 6 new tests.", 40)

_review =
  say.(review, :user, :question, "Does `esc` still close when the reject note is open? That'd lose the note.", 25)

run = add_run.(review, %{status: :done, current_node: nil, started_at: minutes_ago.(95), finished_at: minutes_ago.(30)})
add_ne.(run, %{node: "implement", duration_s: 410, cost: cost.("1.10")})
add_ne.(run, %{node: "quality_review", duration_s: 120, cost: cost.("0.31")})
add_ne.(run, %{node: "merge", duration_s: 55, cost: cost.("0.09")})

# ---------------------------------------------------------------------------
# 6 · Sent back — the rejection banner on a card that re-entered Code.
# ---------------------------------------------------------------------------
rejected =
  new_card.("Code", %{
    title: "Bulk archive stale cards",
    tag: "housekeeping",
    description: description,
    spec: spec,
    plan: plan,
    branch: "RLY-352-bulk-archive"
  })

rejected = ai.(rejected)
rejected = status.(rejected, :working)

rejected
|> Changeset.change()
|> Changeset.put_embed(:rejection, %CardRejection{
  note:
    "Archiving 400 cards fired 400 PubSub broadcasts and the board froze for " <>
      "six seconds. Batch the broadcast into one `cards_bulk_changed` message, " <>
      "and add a test that asserts exactly one message is sent.",
  from_stage_name: "Review",
  to_stage_name: "Code",
  rejected_by: "Jeremy Lightsmith",
  rejected_at: minutes_ago.(6)
})
|> Repo.update!()

rejected =
  say.(
    rejected,
    :user,
    :changes_requested,
    "Batch the broadcast — one message for the whole bulk archive, not one per card.",
    6
  )

run = add_run.(rejected, %{current_node: "implement", started_at: minutes_ago.(4)})
add_ne.(run, %{node: "branch", duration_s: 8, cost: cost.("0.00")})
add_ne.(run, %{node: "implement", outcome: nil, duration_s: nil, cost: nil})

# ---------------------------------------------------------------------------
# 7 · Failed — the circuit breaker tripped, run stopped on a repeat finding.
# ---------------------------------------------------------------------------
failed =
  new_card.("Code", %{
    title: "Saved filters & smart lists",
    tag: "search",
    description: description,
    spec: spec,
    branch: "RLY-360-saved-filters"
  })

failed = ai.(failed)
failed = status.(failed, :working)

run =
  add_run.(failed, %{
    status: :failed,
    current_node: "quality_review",
    started_at: minutes_ago.(15),
    finished_at: minutes_ago.(1)
  })

add_ne.(run, %{node: "implement", duration_s: 160, cost: cost.("0.90")})
add_ne.(run, %{node: "quality_review", outcome: :failed, duration_s: 48, cost: cost.("0.35"), detail: qr_detail})
add_ne.(run, %{node: "implement", attempt: 2, duration_s: 130, cost: cost.("0.72")})
add_ne.(run, %{node: "quality_review", attempt: 2, outcome: :failed, duration_s: 41, cost: cost.("0.30")})
add_ne.(run, %{node: "implement", attempt: 3, duration_s: 118, cost: cost.("0.66")})

add_ne.(run, %{
  node: "quality_review",
  attempt: 3,
  outcome: :failed,
  duration_s: 44,
  cost: cost.("0.31"),
  detail: "test/relay/export_test.exs:24 — 3rd identical failure\n  Same brittle assertion regenerated again."
})

# ---------------------------------------------------------------------------
# 8 · Done — the finished face: done pill, AI result, full run history.
# ---------------------------------------------------------------------------
done =
  new_card.("Done", %{
    title: "Drag-to-reorder stages",
    tag: "board",
    description: """
    Board settings should let an owner drag stages into a new order instead of
    deleting and re-creating them.
    """,
    acceptance_criteria: """
    - Stages drag within the settings list and persist on drop.
    - Card positions survive the reorder.
    - A concurrent editor sees the new order without a refresh.
    """,
    spec: spec,
    plan: plan,
    branch: "RLY-301-reorder-stages",
    pr_url: "https://github.com/relay/relay/pull/301"
  })

done = ai.(done)

done =
  sub_tasks.(done, [
    {"Sortable hook on the settings stage list", true},
    {"Boards.reorder_stages/2 + position rewrite", true},
    {"PubSub broadcast so open boards follow", true}
  ])

{:ok, done} =
  Cards.update_ai_result(done, %{
    "summary" =>
      "Stages now reorder by drag in board settings. Positions are rewritten in one " <>
        "transaction and broadcast on the board topic, so every open board follows " <>
        "without a refresh.",
    "changes" => [
      "lib/relay/boards.ex — reorder_stages/2",
      "lib/relay_web/live/board_settings_live.ex — Sortable hook + drop handler",
      "test/relay/boards_test.exs — position rewrite + concurrency tests"
    ],
    "screens" => [
      %{"caption" => "Settings list mid-drag"},
      %{"caption" => "Board following the new order live"}
    ],
    "deploy_url" => "https://relay-pr-301.fly.dev"
  })

done = say.(done, :agent, :comment, "Merged to main. `mix precommit` green, 9 new tests.", 300)
_done = say.(done, :user, :comment, "Nice — this one's been on the list for months.", 290)

run1 =
  add_run.(done, %{
    status: :done,
    current_node: nil,
    started_at: minutes_ago.(3000),
    finished_at: minutes_ago.(2969),
    inserted_at: minutes_ago.(3000)
  })

add_ne.(run1, %{node: "implement", duration_s: 1500, cost: cost.("3.20")})
add_ne.(run1, %{node: "merge", duration_s: 360, cost: cost.("0.90")})

run2 =
  add_run.(done, %{
    status: :failed,
    current_node: "quality_review",
    started_at: minutes_ago.(1500),
    finished_at: minutes_ago.(1491),
    inserted_at: minutes_ago.(1500)
  })

add_ne.(run2, %{node: "implement", duration_s: 300, cost: cost.("1.10")})
add_ne.(run2, %{node: "quality_review", outcome: :failed, duration_s: 250, cost: cost.("1.18"), detail: qr_detail})

run3 =
  add_run.(done, %{
    status: :done,
    current_node: nil,
    started_at: minutes_ago.(170),
    finished_at: minutes_ago.(123),
    inserted_at: minutes_ago.(170)
  })

add_ne.(run3, %{node: "implement", duration_s: 1200, cost: cost.("2.80")})
add_ne.(run3, %{node: "quality_review", duration_s: 400, cost: cost.("1.40")})
add_ne.(run3, %{node: "merge", duration_s: 220, cost: cost.("2.00")})

# ---------------------------------------------------------------------------
# 9 · Queued — AI-ready in the code flow's pulls-from stage, no run yet.
# ---------------------------------------------------------------------------
queued_stage = Enum.find(board.stages, &(&1.id == code_flow.pulls_from_stage_id)) || stage.("Plan")

queued =
  new_card.(queued_stage.name, %{
    title: "Bulk move cards between stages",
    tag: "board",
    description: description,
    acceptance_criteria: acceptance,
    plan: plan
  })

_queued = ai.(queued)

# ---------------------------------------------------------------------------
# 10 · Archived — the read-only face, with the restore affordance.
# ---------------------------------------------------------------------------
archived =
  new_card.("Backlog", %{
    title: "Slack digest of the daily board",
    tag: "integrations",
    description: """
    A 9am Slack post per board: what moved, what's blocked on a human, what the
    agents finished overnight.
    """,
    acceptance_criteria: acceptance,
    spec: spec,
    plan: plan
  })

archived = mine.(archived)
archived = say.(archived, :user, :comment, "Parking this until the notification work lands.", 5000)
{:ok, _archived} = Cards.archive_card(archived, {:user, user.id})

# ---------------------------------------------------------------------------
# 11 · Activity-heavy — a card with a long, mixed audit trail to shoot the
#      Activity tab against.
# ---------------------------------------------------------------------------
chatty =
  new_card.("Code", %{
    title: "Per-board webhooks",
    tag: "integrations",
    description: description,
    acceptance_criteria: acceptance,
    spec: spec,
    plan: plan,
    branch: "RLY-370-webhooks"
  })

chatty = ai.(chatty)
chatty = status.(chatty, :working)
chatty = sub_tasks.(chatty, [{"Webhook schema + signing", true}, {"Delivery worker with retries", false}])

# `meta` keys are not free-form: `RelayWeb.CoreComponents.activity_phrase/1`
# pattern-matches them, and a shape it has no clause for crashes the drawer.
# Match what `Relay.Activity` actually writes.
for {type, meta, actor} <- [
      {:moved, %{"from_stage" => "Spec", "to_stage" => "Plan"}, {:user, user.id}},
      {:owners_changed, %{"action" => "set", "owners" => ["Relay AI"]}, {:user, user.id}},
      {:moved, %{"from_stage" => "Plan", "to_stage" => "Code"}, :agent},
      {:status_changed, %{"to_status" => "working"}, :agent},
      {:needs_input, %{"question" => "Should deliveries retry forever, or give up after 24h?"}, :agent},
      {:input_answered, %{}, {:user, user.id}},
      {:status_changed, %{"to_status" => "working"}, :agent}
    ] do
  {:ok, _entry} = Activity.log(chatty, %{type: type, actor: actor, meta: meta})
end

for line <- [
      "branch: created RLY-370-webhooks from origin/main",
      "implement: 14 files changed, 612 insertions",
      "precommit: mix format — 0 files changed",
      "precommit: mix credo --strict — 0 issues",
      "quality_review: passed on attempt 1"
    ] do
  {:ok, _entry} = Activity.log(chatty, %{type: :action, actor: :agent, text: line})
end

chatty = say.(chatty, :user, :comment, "Retry for 24h then park it — don't lose deliveries silently.", 90)
_chatty = say.(chatty, :agent, :comment, "Understood — exponential backoff to 24h, then a `webhook_parked` activity row.", 88)

run = add_run.(chatty, %{current_node: "implement", started_at: minutes_ago.(9)})
add_ne.(run, %{node: "branch", duration_s: 8, cost: cost.("0.00")})
add_ne.(run, %{node: "implement", outcome: nil, duration_s: nil, cost: nil})

IO.puts("\nSeeded design-capture board: /board/#{board.slug}\n")

seeded = Repo.all(from c in Schemas.Card, where: c.board_id == ^board.id, order_by: c.ref_number)

for card <- seeded do
  ref = Cards.format_ref(board.key, card.ref_number)
  state = if card.archived_at, do: "archived", else: to_string(card.status)
  IO.puts("  #{String.pad_trailing(ref, 7)} #{String.pad_trailing(state, 12)} #{card.title}")
end
