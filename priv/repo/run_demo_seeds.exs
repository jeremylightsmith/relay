# Seeds a "Run Demo" board with one card per run-visibility state
# (docs/designs/Relay Card Run Panel.dc.html + Relay Board Run Affordances.dc.html):
#
#     mix run priv/repo/run_demo_seeds.exs
#
# Idempotent: the run-demo board is deleted (owner-scoped, by slug) and rebuilt.
#
# Field-name note (RLY-137 vs the ADR 0006 contract this plan was written
# against): `Schemas.NodeExecution` stores `node_key` (not `node`) and has no
# stored `duration_s` column — only `started_at`/`finished_at`, which
# `Relay.Runs.run_summaries_for_board/1` sums the gap of. `Schemas.Run` has no
# `flow_version` column yet (RLY-152; it points at the live flow row
# instead). This script's `add_ne` helper accepts the plan's `node:`/
# `duration_s:` shorthand and derives the real columns.
import Ecto.Query

alias Ecto.Changeset
alias Relay.Boards
alias Relay.Cards
alias Relay.Flows
alias Relay.Repo
alias Schemas.Board
alias Schemas.CardRejection
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

Repo.delete_all(from b in Board, where: b.owner_id == ^user.id and b.slug == "run-demo")

{:ok, board} = Boards.create_board(user, %{name: "Run Demo"})

case_result =
  case board |> Changeset.change(slug: "run-demo") |> Repo.update() do
    {:ok, updated} ->
      updated

    {:error, _changeset} ->
      IO.puts("Could not force slug \"run-demo\" — using generated slug #{board.slug} instead.")
      board
  end

board = Repo.preload(case_result, :stages)

stage = fn name -> Enum.find(board.stages, &(&1.name == name)) || hd(board.stages) end

{:ok, code_flow} = board |> Flows.get_flow!("code") |> Flows.enable_flow()
{:ok, _spec_flow} = board |> Flows.get_flow!("spec") |> Flows.enable_flow()

new_card = fn stage_name, title ->
  {:ok, card} = Cards.create_card(stage.(stage_name), %{title: title})
  {:ok, card} = Cards.assign_ai(card)
  card
end

working = fn card ->
  {:ok, card} = Cards.set_status(card, %{status: :working})
  card
end

add_run = fn card, attrs ->
  defaults = %{
    card_id: card.id,
    flow_key: "code",
    status: :running,
    started_at: minutes_ago.(10)
  }

  Repo.insert!(struct!(Run, Map.merge(defaults, attrs)))
end

# `node:`/`duration_s:` are this seed script's shorthand, not real
# NodeExecution columns — `node` maps to `node_key`, and `duration_s` derives
# `finished_at` from `started_at` (nil duration_s means still in flight, so
# `finished_at` stays nil).
add_ne = fn run, attrs ->
  {node, attrs} = Map.pop(attrs, :node)
  {duration_s, attrs} = Map.pop(attrs, :duration_s, 42)
  {started_at, attrs} = Map.pop(attrs, :started_at, minutes_ago.(1))
  finished_at = duration_s && DateTime.add(started_at, duration_s, :second)

  defaults = %{
    run_id: run.id,
    node_key: node,
    visit: 1,
    attempt: 1,
    outcome: :succeeded,
    started_at: started_at,
    finished_at: finished_at
  }

  Repo.insert!(struct!(NodeExecution, Map.merge(defaults, attrs)))
end

cost = fn s -> Decimal.new(s) end

qr_detail = """
test/relay/export_test.exs:24
  Asserts on %Board{} private struct internals
  (row.__meta__, column ordering). Brittle — assert
  on the CSV bytes the user downloads instead.

→ returned outcome=failed, routed to implement
"""

# 1 · Mid-flight: review-failed loop, implement re-running on a FRESH session.
flight = working.(new_card.("Code", "CSV export of the board"))
run = add_run.(flight, %{current_node: "implement"})
add_ne.(run, %{node: "branch", duration_s: 8, cost: cost.("0.00")})
add_ne.(run, %{node: "implement", duration_s: 160, cost: cost.("0.90")})
add_ne.(run, %{node: "spec_review", duration_s: 31, cost: cost.("0.20")})
add_ne.(run, %{node: "quality_review", outcome: :failed, duration_s: 48, cost: cost.("0.35"), detail: qr_detail})
add_ne.(run, %{node: "implement", attempt: 2, outcome: nil, duration_s: nil, cost: nil})

# 2 · Re-entry: rejected from Review, run re-implementing with the note in context.
reentry = working.(new_card.("Code", "Stream the CSV row by row"))

reentry
|> Changeset.change()
|> Changeset.put_embed(:rejection, %CardRejection{
  note:
    "The CSV should stream row by row, not buffer the whole board in memory — " <>
      "this will OOM on large boards. Also add a header row.",
  from_stage_name: "Review",
  to_stage_name: "Code",
  rejected_by: "Dana",
  rejected_at: minutes_ago.(3)
})
|> Repo.update!()

run = add_run.(reentry, %{current_node: "implement", started_at: minutes_ago.(1)})
add_ne.(run, %{node: "branch", duration_s: 8, cost: cost.("0.00")})
add_ne.(run, %{node: "implement", outcome: nil, duration_s: nil, cost: nil})

# 3 · Parked: spec-flow run waiting on a structured answer (embedded stepper).
parked = new_card.("Spec", "Board search")

{:ok, parked} =
  Cards.request_input(
    parked,
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
  add_run.(parked, %{
    flow_key: "spec",
    status: :parked,
    parked_reason: :needs_input,
    current_node: "brainstorm",
    started_at: minutes_ago.(12)
  })

add_ne.(run, %{node: "brainstorm", outcome: :needs_input, duration_s: 190, cost: cost.("0.15")})

# 4 · Baton revoked: a human claimed the card mid-run; run cancelled, work preserved.
revoked = new_card.("Code", "Legacy import cleanup")
{:ok, revoked} = Cards.set_owners(revoked, [{:user, user.id}], {:user, user.id})

run =
  add_run.(revoked, %{
    status: :cancelled,
    current_node: "implement",
    started_at: minutes_ago.(20),
    finished_at: minutes_ago.(2)
  })

add_ne.(run, %{node: "branch", duration_s: 8, cost: cost.("0.00")})
add_ne.(run, %{node: "implement", outcome: nil, duration_s: 72, cost: cost.("0.40")})

# 5 · Circuit breaker: quality_review failed 3× on the same finding; run stopped.
circuit = working.(new_card.("Code", "Saved filters & smart lists"))

run =
  add_run.(circuit, %{
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

# 6 · Done with totals: run landed the card on Review's done sub-lane equivalent.
done = new_card.("Review", "Drag-to-reorder stages")
run = add_run.(done, %{status: :done, current_node: nil, started_at: minutes_ago.(70), finished_at: minutes_ago.(9)})
add_ne.(run, %{node: "branch", duration_s: 8, cost: cost.("0.00")})
add_ne.(run, %{node: "implement", duration_s: 322, cost: cost.("0.24")})
add_ne.(run, %{node: "precommit", duration_s: 190, cost: cost.("0.00")})
add_ne.(run, %{node: "merge", duration_s: 61, cost: cost.("0.14")})

# 7 · Your review: run done, card waiting on the human review gate.
review = new_card.("Review", "Card drawer keyboard shortcuts")
{:ok, review} = Cards.set_status(review, %{status: :in_review})
run = add_run.(review, %{status: :done, current_node: nil, started_at: minutes_ago.(95), finished_at: minutes_ago.(30)})
add_ne.(run, %{node: "implement", duration_s: 410, cost: cost.("1.10")})
add_ne.(run, %{node: "merge", duration_s: 55, cost: cost.("0.09")})

# 8 · Cancelled · claimed (face state): same shape as revoked, different card.
cancelled = new_card.("Code", "Bulk archive stale cards")
{:ok, cancelled} = Cards.set_owners(cancelled, [{:user, user.id}], {:user, user.id})

run =
  add_run.(cancelled, %{
    status: :cancelled,
    current_node: "implement",
    started_at: minutes_ago.(40),
    finished_at: minutes_ago.(25)
  })

add_ne.(run, %{node: "implement", outcome: nil, duration_s: 45, cost: cost.("0.21")})

# 9 · Queued: AI-ready card in the enabled code flow's pulls-from stage, no run.
queued_stage = Enum.find(board.stages, &(&1.id == code_flow.pulls_from_stage_id))
{:ok, queued} = Cards.create_card(queued_stage, %{title: "Bulk move cards between stages"})
{:ok, _queued} = Cards.assign_ai(queued)

# 10 · History: three prior runs (done · failed · done), inspectable after the fact.
history = new_card.("Review", "Keyboard shortcuts for the card drawer")

run1 =
  add_run.(history, %{
    status: :done,
    current_node: nil,
    started_at: minutes_ago.(3000),
    finished_at: minutes_ago.(2969),
    inserted_at: minutes_ago.(3000)
  })

add_ne.(run1, %{node: "implement", duration_s: 1500, cost: cost.("3.20")})
add_ne.(run1, %{node: "merge", duration_s: 360, cost: cost.("0.90")})

run2 =
  add_run.(history, %{
    status: :failed,
    current_node: "quality_review",
    started_at: minutes_ago.(1500),
    finished_at: minutes_ago.(1491),
    inserted_at: minutes_ago.(1500)
  })

add_ne.(run2, %{node: "implement", duration_s: 300, cost: cost.("1.10")})
add_ne.(run2, %{node: "quality_review", outcome: :failed, duration_s: 250, cost: cost.("1.18"), detail: qr_detail})

run3 =
  add_run.(history, %{
    status: :done,
    current_node: nil,
    started_at: minutes_ago.(170),
    finished_at: minutes_ago.(123),
    inserted_at: minutes_ago.(170)
  })

add_ne.(run3, %{node: "implement", attempt: 1, duration_s: 1200, cost: cost.("2.80")})
add_ne.(run3, %{node: "quality_review", duration_s: 400, cost: cost.("1.40")})
add_ne.(run3, %{node: "merge", duration_s: 220, cost: cost.("2.00")})

IO.puts("Seeded run-demo board: http://localhost:4000/board/#{board.slug}")
