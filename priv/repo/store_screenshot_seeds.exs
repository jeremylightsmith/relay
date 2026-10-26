# Seeds "Forkful" — someone else's project (a recipe site) on a design-led board — for the App
# Store screenshots (RE479, flutter/docs/DEPLOYMENT.md § "Store screenshots"):
#
#     mix run priv/repo/store_screenshot_seeds.exs
#
# The board is owned by the dev user, the same user `GET /dev/login` signs in, so the simulator
# capture (bin/capture_store_screenshots.sh) sees it. It carries every state a shot shows: a
# Needs-you inbox, agents working in Design, Plan and Code, the "Redesign the recipe page"
# card waiting in Design · Review with two recipe-page mockups, and a structured question for the
# Answer shot. Idempotent: the Forkful board is deleted (owner-scoped, by slug) and rebuilt.
import Ecto.Query

alias Ecto.Changeset
alias Hamaca.Accounts
alias Hamaca.Attachments
alias Hamaca.Boards
alias Hamaca.Cards
alias Hamaca.Flows
alias Hamaca.Repo
alias Hamaca.Runs
alias Schemas.Board
alias Schemas.BoardSetupStep
alias Schemas.NodeExecution
alias Schemas.Run

assets = Path.join(__DIR__, "store_screenshot_seeds")
now = DateTime.truncate(DateTime.utc_now(), :second)
minutes_ago = fn m -> DateTime.add(now, -m * 60, :second) end

owner = Accounts.ensure_dev_user!()

# On a re-seed the app boots with the previous board's runs still active, and their RunServers
# write node jobs while this delete cascades through them — Postgres may pick the delete as the
# deadlock victim. Retry it a few times rather than fail the seed.
delete_previous = fn delete_previous, attempts_left ->
  try do
    Repo.delete_all(from b in Board, where: b.owner_id == ^owner.id and b.slug == "forkful")
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :deadlock_detected and attempts_left > 0 do
        Process.sleep(200)
        delete_previous.(delete_previous, attempts_left - 1)
      else
        reraise error, __STACKTRACE__
      end
  end
end

delete_previous.(delete_previous, 5)

{:ok, board} =
  Boards.create_board(owner, %{name: "Forkful", slug: "forkful", key: "FK", template: "design-led"})

# Someone else's project, well under way: the first-run setup checklist is long behind it (a
# board with no setup rows reads like one made before the checklist existed), and a runner is
# connected. Its 1h interval keeps it fresh for the length of a capture, so the work queued for
# the agents below reads as in hand, not as "no runner is connected".
Repo.delete_all(from s in BoardSetupStep, where: s.board_id == ^board.id)

{:ok, _runner} =
  Runs.upsert_runner(board, %{
    "name" => "forkful-studio",
    "host" => "forkful-studio",
    "interval" => 3600,
    "version" => Runs.min_runner_version()
  })

stage = fn name -> Enum.find(board.stages, &(&1.name == name)) || raise "no stage #{name}" end

design_review =
  "Design"
  |> stage.()
  |> Boards.sublanes()
  |> Enum.find(&(&1.type == :review)) || raise "the Design stage has no Review lane"

flows =
  Map.new(~w(design plan code), fn key ->
    {:ok, flow} = board |> Flows.get_flow!(key) |> Flows.enable_flow()
    {key, flow}
  end)

card = fn stage_or_name, title, opts ->
  target = if is_binary(stage_or_name), do: stage.(stage_or_name), else: stage_or_name
  {:ok, card} = Cards.create_card(target, %{title: title, tag: opts[:tag]})

  {:ok, card} =
    case opts[:owners] do
      nil -> Cards.assign_ai(card)
      owners -> Cards.set_owners(card, owners, {:user, owner.id})
    end

  card
end

working = fn card ->
  {:ok, card} = Cards.set_status(card, %{status: :working})
  card |> Changeset.change(agent_heartbeat_at: now) |> Repo.update!()
end

in_review = fn card ->
  {:ok, card} = Cards.set_status(card, %{status: :in_review})
  card
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

agent_working = fn stage_name, title, flow_key, nodes, started ->
  card = working.(card.(stage_name, title, []))
  {current, _seconds, _cost} = List.last(nodes)
  run = add_run.(card, %{flow_key: flow_key, current_node: current, started_at: minutes_ago.(started)})
  add_nodes.(run, nodes)
  card
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

# The mockups are standalone files; attachments are served one at a time, so the photo rides
# inside each one as a data URI rather than a relative <img src>.
photo_uri = "data:image/jpeg;base64," <> Base.encode64(File.read!(Path.join(assets, "recipe_photo.jpg")))

mockup = fn card, file, caption ->
  html = assets |> Path.join(file) |> File.read!() |> String.replace(~s(src="recipe_photo.jpg"), ~s(src="#{photo_uri}"))

  {:ok, attachment} =
    Attachments.create_attachment(card, %{filename: file, content_type: "text/html", bytes: html})

  %{"url" => "/attachments/#{attachment.id}", "caption" => caption}
end

# ── Unstarted ────────────────────────────────────────────────────────────────
card.("Backlog", "Print-friendly recipe cards", owners: [{:user, owner.id}])
card.("Backlog", "Metric / imperial toggle", owners: [{:user, owner.id}])
card.("Backlog", "Search by what's in the pantry", owners: [{:user, owner.id}])
card.("Next up", "Shopping list from a recipe", [])
card.("Next up", "Weekly meal planner", [])

# ── Design ───────────────────────────────────────────────────────────────────
agent_working.("Design", "Saved-recipes page", "design", [{"mockups", nil, nil}], 5)

"Design"
|> card.("Ratings and reviews", [])
|> park_on_question.(
  "design",
  "mockups",
  [
    %{
      "prompt" => "Should star ratings be public, or private notes only you can see?",
      "options" => ["Public ratings", "Private notes only"],
      "allow_text" => true
    }
  ],
  14
)

recipe_page = card.(design_review, "Redesign the recipe page", owners: [:agent, {:user, owner.id}])

{:ok, recipe_page} =
  Cards.set_mockups(recipe_page, [
    mockup.(recipe_page, "recipe_mockup_a.html", "A — photo header, two columns"),
    mockup.(recipe_page, "recipe_mockup_b.html", "B — method first, photo beside")
  ])

{:ok, recipe_page} =
  Cards.update_ai_result(recipe_page, %{"summary" => "Two layouts for the recipe page. A leads with the photo."})

in_review.(recipe_page)

# ── Plan ─────────────────────────────────────────────────────────────────────
agent_working.("Plan", "Serving-size scaler", "plan", [{"write_plan", nil, nil}], 7)

"Plan"
|> card.("Sync saved recipes", [])
|> park_on_question.(
  "plan",
  "write_plan",
  [
    %{
      "prompt" => "Should saved recipes sync across devices, or stay on this phone?",
      "options" => ["Sync across devices", "Keep them on this phone"],
      "allow_text" => true
    }
  ],
  9
)

# ── Build and ship ───────────────────────────────────────────────────────────
agent_working.(
  "Code",
  "Cook mode that keeps the screen awake",
  "code",
  [{"branch", 6, "0.00"}, {"implement", nil, nil}],
  11
)

agent_working.(
  "Code",
  "Tick off ingredients as you go",
  "code",
  [{"branch", 7, "0.00"}, {"implement", 610, "1.30"}, {"review", nil, nil}],
  19
)

in_review.(card.("Review", "Nutrition facts panel", []))

# Design-led boards deploy by hand, so the card in Deploy is a person's.
card.("Deploy", "Recipe structured data for search", owners: [{:user, owner.id}])

# ── Done ─────────────────────────────────────────────────────────────────────
for title <- ["Sign in with Apple", "Recipe photo uploads", "Search by ingredient"] do
  card.("Done", title, owners: [{:user, owner.id}])
end

IO.puts("Seeded Forkful board: #{Application.fetch_env!(:hamaca, :app_url)}/board/#{board.slug}")
