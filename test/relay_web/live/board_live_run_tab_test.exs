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
    stage = Enum.find(ctx.board.stages, &(&1.id == flow.pulls_from_stage_id))
    {:ok, card} = Cards.create_card(stage, %{title: "Waiting"})
    {:ok, card} = Cards.assign_ai(card)
    ref = Cards.ref(ctx.board, card)

    view = open(ctx.conn, ctx.board, ref)

    assert has_element?(view, "#card-drawer-tab-run")
    assert has_element?(view, "#card-drawer-tab-panel-run", "QUEUED")
  end

  test "a parked run hosts the stepper in the Run tab and answering clears it", ctx do
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

    refute has_element?(view, "#card-drawer-tab-panel-run.hidden")
    assert has_element?(view, "#card-drawer-tab-panel-run #needs-input-stepper")
    refute has_element?(view, "#card-drawer-tab-panel-detail #needs-input-panel")

    view |> element("#needs-input-option-0") |> render_click()
    view |> element("#needs-input-send") |> render_click()

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

  test "prior runs stay inspectable under the history section", ctx do
    card = ai_card(ctx.code, "History card")
    old = insert(:run, card: card, status: :failed, current_node: "quality_review", inserted_at: ~U[2026-07-01 10:00:00Z])
    insert(:node_execution, run: old, node: "quality_review", outcome: :failed, duration_s: 250, detail: "old failure")
    insert(:run, card: card, status: :done, current_node: nil, finished_at: DateTime.utc_now())
    ref = Cards.ref(ctx.board, card)

    view = open(ctx.conn, ctx.board, ref)
    view |> element("#card-drawer-tab-run") |> render_click()

    assert has_element?(view, "#card-drawer-tab-panel-run", "PRIOR RUNS · 1")
    assert has_element?(view, "#card-drawer-tab-panel-run", "old failure")
  end
end
