defmodule RelayWeb.BoardLiveRunTabTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Flows

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    %{board: board, code: code}
  end

  defp open(conn, board, ref) do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
    render_async(view)
    view
  end

  defp count(view, selector), do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()

  defp ai_card(stage, title) do
    {:ok, card} = Cards.create_card(stage, %{title: title})
    {:ok, card} = Cards.assign_ai(card)
    {:ok, card} = Cards.set_status(card, %{status: :working})
    card
  end

  test "a card with no runs and no queue shows Detail and Activity only", ctx do
    {:ok, card} = Cards.create_card(ctx.code, %{title: "Human card"})
    ref = Cards.ref(ctx.board, card)
    view = open(ctx.conn, ctx.board, ref)

    assert has_element?(view, "#card-drawer-tab-detail")
    assert has_element?(view, "#card-drawer-tab-activity")
    refute has_element?(view, "#card-drawer-tab-run")
    refute has_element?(view, "#card-drawer-tab-panel-detail.hidden")
  end

  test "a card with an active run opens on the Run tab with the timeline", ctx do
    card = ai_card(ctx.code, "Mid flight")
    run = insert(:run, card: card, current_node: "implement")
    insert(:node_execution, run: run, node: "branch", duration_s: 8)
    insert(:node_execution, run: run, node: "quality_review", outcome: :failed, duration_s: 48, detail: "brittle assert")
    insert(:node_execution, run: run, node: "implement", attempt: 2, outcome: nil, duration_s: nil)
    ref = Cards.ref(ctx.board, card)

    view = open(ctx.conn, ctx.board, ref)

    assert has_element?(view, "#card-drawer-tab-run")
    refute has_element?(view, "#card-drawer-tab-panel-run.hidden")
    assert has_element?(view, "#card-drawer-tab-panel-detail.hidden")
    assert has_element?(view, "#card-drawer-tab-panel-run", "quality_review")
    assert has_element?(view, "#card-drawer-tab-panel-run", "OUTCOME: FAILED")
    assert has_element?(view, "#card-drawer-tab-panel-run", "attempt 2")
    refute has_element?(view, "#card-drawer-tab-panel-run", "session resumed")

    # RE426 — the latest run is the open head of the one run list
    assert has_element?(view, "#card-drawer-tab-panel-run #run-list")
    assert has_element?(view, "#run-entry-1[open]")
    assert has_element?(view, "#run-entry-1 .run-entry-latest")
    assert has_element?(view, "#run-entry-1 .run-entry-meta", "elapsed")
  end

  defp two_flow_card(ctx) do
    spec = Flows.get_flow!(ctx.board, "spec")
    code = Flows.get_flow!(ctx.board, "code")
    card = ai_card(ctx.code, "Two flows")

    insert(:run,
      card: card,
      flow_id: spec.id,
      flow_key: spec.key,
      status: :done,
      current_node: nil,
      inserted_at: ~U[2026-07-01 10:00:00Z],
      finished_at: ~U[2026-07-01 10:30:00Z]
    )

    insert(:run, card: card, flow_id: code.id, flow_key: code.key)
    card
  end

  test "every run is one entry in a single RUNS list, the latest open and tinted (RE426)", ctx do
    card = two_flow_card(ctx)

    view = open(ctx.conn, ctx.board, Cards.ref(ctx.board, card))

    assert has_element?(view, "#card-drawer-tab-panel-run", "RUNS · 2")
    assert view |> element("#run-entry-2 .run-entry-stage") |> render() =~ ~r/>\s*CODE\s*</
    assert view |> element("#run-entry-1 .run-entry-stage") |> render() =~ ~r/>\s*SPEC\s*</
    assert has_element?(view, "#run-entry-2[open]")
    refute has_element?(view, "#run-entry-1[open]")
    assert has_element?(view, "#run-entry-2[style*='var(--color-secondary) 35%']")
  end

  test "the Run tab has no status strip and no baton pill (RE426)", ctx do
    card = two_flow_card(ctx)

    view = open(ctx.conn, ctx.board, Cards.ref(ctx.board, card))

    refute has_element?(view, ".run-strip")
    refute render(element(view, "#card-drawer-tab-panel-run")) =~ "BATON"
  end

  test "a done latest run still shows its node timeline and stats (RE426)", ctx do
    card = ai_card(ctx.code, "All done")
    run = insert(:run, card: card, status: :done, current_node: nil, finished_at: DateTime.utc_now())
    insert(:node_execution, run: run, node: "merge", outcome: :succeeded, duration_s: 30)

    view = open(ctx.conn, ctx.board, Cards.ref(ctx.board, card))
    view |> element("#card-drawer-tab-run") |> render_click()

    assert has_element?(view, "#run-entry-1[open]")
    assert has_element?(view, "#run-entry-1[style*='var(--color-success) 35%']")
    assert has_element?(view, "#run-entry-1 .run-node-timeline", "merge")
    assert has_element?(view, "#run-entry-1 .run-entry-stats")
  end

  test "only the latest of several runs is open (RE426)", ctx do
    card = ai_card(ctx.code, "Three runs")

    insert(:run,
      card: card,
      status: :cancelled,
      current_node: nil,
      inserted_at: ~U[2026-07-01 10:00:00Z],
      finished_at: ~U[2026-07-01 10:10:00Z]
    )

    insert(:run,
      card: card,
      status: :failed,
      current_node: nil,
      inserted_at: ~U[2026-07-02 10:00:00Z],
      finished_at: ~U[2026-07-02 10:10:00Z]
    )

    insert(:run, card: card)

    view = open(ctx.conn, ctx.board, Cards.ref(ctx.board, card))

    assert count(view, "details.run-entry[open]") == 1
    assert has_element?(view, "#run-entry-3[open]")
    refute has_element?(view, "#run-entry-2[open]")
    refute has_element?(view, "#run-entry-1[open]")
  end

  test "the flow-metrics and value-stream links sit inside the latest entry (RE426)", ctx do
    code = Flows.get_flow!(ctx.board, "code")
    card = ai_card(ctx.code, "Linked")
    insert(:run, card: card, flow_id: code.id, flow_key: code.key)

    view = open(ctx.conn, ctx.board, Cards.ref(ctx.board, card))

    assert has_element?(view, "#run-entry-1 #run-view-in-flow-metrics")
    assert has_element?(view, "#run-entry-1 #card-value-stream-link")
  end

  test "a run whose flow was deleted falls back to its flow key for the stage chip (RE426)", ctx do
    card = ai_card(ctx.code, "Orphan flow")
    insert(:run, card: card, flow_id: nil, flow_key: "code")

    view = open(ctx.conn, ctx.board, Cards.ref(ctx.board, card))

    assert view |> element("#run-entry-1 .run-entry-stage") |> render() =~ ~r/>\s*CODE\s*</
  end

  # RLY-179 smoke regression: a run that died with nowhere to route is NOT a tripped
  # breaker. The Run tab used to shout "CIRCUIT BREAKER TRIPPED" for every failure and
  # then contradict itself on the next line with "fixit returned failed 1 time".
  test "a non-breaker failure states its reason instead of claiming a circuit breaker", ctx do
    card = ai_card(ctx.code, "Nowhere to go")
    {:ok, card} = Cards.set_status(card, %{status: :failed})

    run =
      insert(:run,
        card: card,
        status: :failed,
        current_node: nil,
        finished_at: DateTime.utc_now(),
        failure_detail:
          "The flow has nowhere to go after `fixit` reported `failed`. (no_route_for_outcome: fixit → failed)"
      )

    insert(:node_execution, run: run, node: "fixit", outcome: :failed, duration_s: 30, detail: "could not fix the spec")

    view = open(ctx.conn, ctx.board, Cards.ref(ctx.board, card))

    refute has_element?(view, "#card-drawer-tab-panel-run", "CIRCUIT BREAKER")
    assert has_element?(view, "#card-drawer-tab-panel-run", "RUN FAILED")
    assert has_element?(view, "#card-drawer-tab-panel-run", "The flow has nowhere to go after")
    assert has_element?(view, "#run-entry-1", "RUN FAILED")
  end

  test "a genuinely tripped breaker still gets the circuit banner", ctx do
    card = ai_card(ctx.code, "Looped forever")
    {:ok, card} = Cards.set_status(card, %{status: :failed})

    run =
      insert(:run,
        card: card,
        status: :failed,
        current_node: nil,
        finished_at: DateTime.utc_now(),
        failure_detail: "circuit_breaker: the same failure repeated 3 times"
      )

    for attempt <- 1..3 do
      insert(:node_execution,
        run: run,
        node: "quality_review",
        attempt: attempt,
        outcome: :failed,
        duration_s: 30,
        detail: "same finding"
      )
    end

    view = open(ctx.conn, ctx.board, Cards.ref(ctx.board, card))

    assert has_element?(view, "#card-drawer-tab-panel-run", "CIRCUIT BREAKER TRIPPED")
    assert has_element?(view, "#card-drawer-tab-panel-run", "quality_review")
  end

  test "a card with only terminal runs opens on Detail; Run tab still renders", ctx do
    card = ai_card(ctx.code, "Done before")
    insert(:run, card: card, status: :done, current_node: nil, finished_at: DateTime.utc_now())
    ref = Cards.ref(ctx.board, card)

    view = open(ctx.conn, ctx.board, ref)

    assert has_element?(view, "#card-drawer-tab-run")
    refute has_element?(view, "#card-drawer-tab-panel-detail.hidden")
  end

  test "clicking tabs swaps the visible panel and the activity log lives under Activity", ctx do
    card = ai_card(ctx.code, "Tabbed")
    insert(:run, card: card)
    ref = Cards.ref(ctx.board, card)
    view = open(ctx.conn, ctx.board, ref)

    assert has_element?(view, "#card-drawer-tab-panel-activity.hidden #card-drawer-activity")

    view |> element("#card-drawer-tab-activity") |> render_click()

    refute has_element?(view, "#card-drawer-tab-panel-activity.hidden")
    assert has_element?(view, "#card-drawer-tab-panel-run.hidden")
  end

  test "a queued card shows the Run tab with the queued state", ctx do
    flow = Flows.get_flow!(ctx.board, "code")
    {:ok, flow} = Flows.enable_flow(flow)
    stage = Flows.neighbours(flow).pulls_from
    {:ok, card} = Cards.create_card(stage, %{title: "Waiting"})
    {:ok, card} = Cards.assign_ai(card)
    ref = Cards.ref(ctx.board, card)

    view = open(ctx.conn, ctx.board, ref)

    assert has_element?(view, "#card-drawer-tab-run")
    assert has_element?(view, "#card-drawer-tab-panel-run", "QUEUED")
  end

  test "a parked run's Run tab carries no answer surface; the stepper lives on Detail (RE279)", ctx do
    card = ai_card(ctx.code, "Parked one")

    {:ok, card} =
      Cards.request_input(
        card,
        [%{"prompt" => "Full text or titles?", "options" => ["Full text", "Titles"], "allow_text" => false}],
        :agent
      )

    run = insert(:run, card: card, flow_key: "spec", status: :parked, current_node: "brainstorm")
    insert(:node_execution, run: run, node: "brainstorm", outcome: :needs_input, duration_s: 190)
    ref = Cards.ref(ctx.board, card)

    view = open(ctx.conn, ctx.board, ref)

    # RE325 — a blocked card opens on Detail; the Run tab is a click away
    refute has_element?(view, "#card-drawer-tab-panel-detail.hidden")
    view |> element("#card-drawer-tab-run") |> render_click()

    refute has_element?(view, "#card-drawer-tab-panel-run.hidden")
    assert view |> element("#run-entry-1 .run-entry-status") |> render() =~ ~r/>\s*Parked\s*</
    assert has_element?(view, "#run-entry-1[style*='var(--color-warning) 35%']")
    assert has_element?(view, "#run-entry-1 .run-node-timeline", "brainstorm")
    refute has_element?(view, ".run-banner-parked")
    refute has_element?(view, "#run-needs-input-panel")
    refute has_element?(view, "#card-drawer-tab-panel-run #needs-input-panel")
    assert has_element?(view, "#card-drawer-tab-panel-detail #needs-input-stepper")

    # RE323 — on a single-question batch the option click itself sends the answer
    view |> element("#needs-input-option-0") |> render_click()

    card = Relay.Repo.reload!(card)
    assert card.status == :working
    assert_patch(view, ~p"/board/#{ctx.board.slug}")
  end

  test "a legacy needs-input card (no runs) keeps the stepper in Detail", ctx do
    {:ok, card} = Cards.create_card(ctx.code, %{title: "Legacy block"})
    {:ok, card} = Cards.assign_ai(card)
    {:ok, card} = Cards.request_input(card, "Which auth provider?", :agent)
    ref = Cards.ref(ctx.board, card)

    view = open(ctx.conn, ctx.board, ref)

    refute has_element?(view, "#card-drawer-tab-run")
    assert has_element?(view, "#card-drawer-tab-panel-detail #needs-input-panel")
  end

  test "earlier runs stay inspectable as collapsed entries in the run list", ctx do
    card = ai_card(ctx.code, "History card")
    old = insert(:run, card: card, status: :failed, current_node: "quality_review", inserted_at: ~U[2026-07-01 10:00:00Z])
    insert(:node_execution, run: old, node: "quality_review", outcome: :failed, duration_s: 250, detail: "old failure")
    insert(:run, card: card, status: :done, current_node: nil, finished_at: DateTime.utc_now())
    ref = Cards.ref(ctx.board, card)

    view = open(ctx.conn, ctx.board, ref)
    view |> element("#card-drawer-tab-run") |> render_click()

    assert has_element?(view, "#card-drawer-tab-panel-run", "RUNS · 2")
    refute has_element?(view, "#card-drawer-tab-panel-run", "PRIOR")
    assert has_element?(view, "#run-entry-1", "old failure")
    refute has_element?(view, "#run-entry-1[open]")
  end
end
