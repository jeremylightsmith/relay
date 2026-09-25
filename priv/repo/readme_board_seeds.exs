# Seeds a healthy, realistic "Relay" board for the README screenshot (docs/images/board.png):
#
#     mix run priv/repo/readme_board_seeds.exs
#
# Unlike run_demo_seeds.exs (a QA fixture with one card per run state, including cancelled
# and failed runs), this board shows the product on a good day: agents working in Spec and
# Code, a couple of cards waiting on a human answer, and only genuinely in-review cards in
# Review. Idempotent: the readme board is deleted (owner-scoped, by slug) and rebuilt.
import Ecto.Query

alias Ecto.Changeset
alias Relay.Accounts
alias Relay.Boards
alias Relay.Cards
alias Relay.Flows
alias Relay.Members
alias Relay.Repo
alias Schemas.Board
alias Schemas.NodeExecution
alias Schemas.Run
alias Schemas.User

now = DateTime.truncate(DateTime.utc_now(), :second)
minutes_ago = fn m -> DateTime.add(now, -m * 60, :second) end

seed_user = fn email, name ->
  case Repo.get_by(User, email: email) do
    nil ->
      %User{provider: "seed", provider_uid: "seed-" <> email}
      |> User.changeset(%{email: email, name: name})
      |> Repo.insert!()

    %User{} = existing ->
      existing
  end
end

owner = seed_user.("jeremy.lightsmith@gmail.com", "Jeremy Lightsmith")
dana = seed_user.("dana@relay.example", "Dana Okafor")
sam = seed_user.("sam@relay.example", "Sam Reyes")

Repo.delete_all(from b in Board, where: b.owner_id == ^owner.id and b.slug == "readme")

{:ok, board} = Boards.create_board(owner, %{name: "Relay", slug: "readme", key: "RE"})

dev_user = Accounts.ensure_dev_user!()

for user <- [dana, sam, dev_user] do
  case Members.invite(board, user.email) do
    {:ok, _membership} -> :ok
    {:error, :already_member} -> :ok
  end
end

stage = fn name -> Enum.find(board.stages, &(&1.name == name)) || raise "no stage #{name}" end

# Keep the 1440px screenshot on the hand-off stages (Spec → Plan → Code → Review).
for name <- ["Backlog", "Next up"] do
  {:ok, _} = Boards.update_stage(stage.(name), %{collapsed_by_default: true})
end

flows =
  Map.new(~w(spec plan code), fn key ->
    {:ok, flow} = board |> Flows.get_flow!(key) |> Flows.enable_flow()
    {key, flow}
  end)

card = fn stage_name, title, opts ->
  {:ok, card} = Cards.create_card(stage.(stage_name), %{title: title, tag: opts[:tag]})

  {:ok, card} =
    case opts[:owner] do
      nil -> Cards.assign_ai(card)
      %User{id: id} -> Cards.set_owners(card, [{:user, id}], {:user, id})
    end

  card
end

working = fn card ->
  {:ok, card} = Cards.set_status(card, %{status: :working})
  card |> Changeset.change(agent_heartbeat_at: now) |> Repo.update!()
end

add_run = fn card, attrs ->
  flow = Map.fetch!(flows, Map.get(attrs, :flow_key, "code"))

  Repo.insert!(
    struct!(
      Run,
      Map.merge(
        %{card_id: card.id, flow_key: flow.key, flow_id: flow.id, status: :running, started_at: minutes_ago.(12)},
        attrs
      )
    )
  )
end

# `nodes` is [{node_key, seconds, cost}] run back to back; a nil seconds is the node in flight.
add_nodes = fn run, nodes ->
  Enum.reduce(nodes, run.started_at, fn {node, seconds, cost}, started_at ->
    finished_at = seconds && DateTime.add(started_at, seconds, :second)

    Repo.insert!(%NodeExecution{
      run_id: run.id,
      node_key: node,
      visit: 1,
      attempt: 1,
      outcome: if(seconds, do: :succeeded),
      started_at: started_at,
      finished_at: finished_at,
      cost: cost && Decimal.new(cost)
    })

    finished_at || started_at
  end)
end

# A genuine question (not an escalated failure), so the card reads "needs you" rather than stalled.
park_on_question = fn card, flow_key, node, questions, started ->
  {:ok, card} = Cards.request_input(card, questions, :agent)

  run =
    add_run.(card, %{
      flow_key: flow_key,
      status: :parked,
      parked_reason: :needs_input,
      current_node: node,
      started_at: minutes_ago.(started)
    })

  Repo.insert!(%NodeExecution{
    run_id: run.id,
    node_key: node,
    visit: 1,
    attempt: 1,
    outcome: :needs_input,
    started_at: run.started_at,
    finished_at: minutes_ago.(started - 3),
    cost: Decimal.new("0.18")
  })

  card
end

shipped = fn card, minutes, nodes ->
  run = add_run.(card, %{status: :done, current_node: nil, started_at: minutes_ago.(minutes)})
  finished_at = add_nodes.(run, nodes)
  run |> Changeset.change(finished_at: finished_at) |> Repo.update!()
end

# ── Unstarted ────────────────────────────────────────────────────────────────
card.("Backlog", "Slack notifications when a card needs you", owner: dana)
card.("Backlog", "Dark mode for the public board", owner: sam)
card.("Backlog", "Import cards from a GitHub project", owner: dana)
card.("Next up", "Card templates", [])
card.("Next up", "Bulk move cards between stages", [])

# ── Planning ─────────────────────────────────────────────────────────────────
spec_running = working.(card.("Spec", "Recurring cards", []))
run = add_run.(spec_running, %{flow_key: "spec", current_node: "brainstorm", started_at: minutes_ago.(4)})
add_nodes.(run, [{"brainstorm", nil, nil}])

"Spec"
|> card.("Board search", [])
|> park_on_question.(
  "spec",
  "brainstorm",
  [
    %{
      "prompt" => "Should search cover card bodies and comments, or just titles?",
      "options" => ["Full-text: bodies + comments", "Titles only for now"],
      "allow_text" => true
    }
  ],
  9
)

spec_review = card.("Spec:Review", "Per-board WIP limits", [])
{:ok, _} = Cards.set_status(spec_review, %{status: :in_review})

card.("Spec:Done", "Undo a card move", [])

plan_running = working.(card.("Plan", "Webhooks for card events", []))
run = add_run.(plan_running, %{flow_key: "plan", current_node: "write_plan", started_at: minutes_ago.(6)})
add_nodes.(run, [{"write_plan", nil, nil}])

card.("Plan:Done", "Keyboard shortcuts for the card drawer", [])

# ── In progress ──────────────────────────────────────────────────────────────
implementing = working.(card.("Code", "Export the board as CSV", []))
run = add_run.(implementing, %{current_node: "implement", started_at: minutes_ago.(9)})
add_nodes.(run, [{"branch", 6, "0.00"}, {"implement", nil, nil}])

reviewing = working.(card.("Code", "Paginate the activity feed", []))
run = add_run.(reviewing, %{current_node: "quality_review", started_at: minutes_ago.(22)})

add_nodes.(run, [
  {"branch", 7, "0.00"},
  {"implement", 640, "1.40"},
  {"spec_review", 95, "0.22"},
  {"quality_review", nil, nil}
])

"Code"
|> card.("Saved filters & smart lists", [])
|> park_on_question.(
  "code",
  "implement",
  [
    %{
      "prompt" => "Should saved filters be private to you, or shared with everyone on the board?",
      "options" => ["Private", "Shared with the board"],
      "allow_text" => true
    }
  ],
  18
)

for {title, minutes, cost} <- [
      {"Drag to reorder stages", 64, "2.10"},
      {"Show run cost on each card", 48, "1.35"}
    ] do
  review = card.("Review", title, [])
  {:ok, review} = Cards.set_status(review, %{status: :in_review})

  shipped.(review, minutes, [
    {"branch", 8, "0.00"},
    {"implement", 900, cost},
    {"precommit", 180, "0.00"},
    {"merge", 60, "0.10"}
  ])
end

# ── Done ─────────────────────────────────────────────────────────────────────
for title <- ["Story map view", "Sign in with Google", "Public board sharing"] do
  card.("Done", title, owner: dana)
end

IO.puts("Seeded readme board: http://localhost:4000/board/#{board.slug}")
