defmodule RelayWeb.BoardLiveInfrastructureParkTest do
  @moduledoc """
  RE308 — a run parked because its agent could not run at all (an expired login, a usage limit:
  the runner reported `:blocked`) renders its own drawer face: "AGENT COULD NOT RUN", the cause in
  a code block, and Retry. Nothing to answer, and no attempt count, because no retry was spent.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Cards
  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeJob

  setup :register_and_log_in_user

  setup %{user: user} do
    FakeDispatcher.register(self())
    board = Relay.Boards.get_or_create_default_board(user)
    flow = one_node_flow(board)
    start_engine!()
    %{board: board, flow: flow}
  end

  defp one_node_flow(board) do
    next_up = Enum.find(board.stages, &(&1.name == "Next up"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    review = Enum.find(board.stages, &(&1.name == "Spec:Review"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "infra-flow",
        isolation: :shared_clean,
        pulls_from_stage_id: next_up.id,
        works_in_stage_id: spec.id,
        lands_on_stage_id: review.id,
        nodes: [%{key: "brainstorm", type: :agent, run: "/brainstorm {ref}", max_retries: 2}],
        edges: [%{from: "start", to: "brainstorm"}, %{from: "brainstorm", to: "done", on: :succeeded}]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  @oauth "agent could not run: Failed to authenticate: OAuth session expired and could not be refreshed"

  defp blocked_park(board, flow) do
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Cards.create_card(stage, %{title: "Expired login"})
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{} = job}
    {:ok, _run} = Runs.report_outcome(job, %{outcome: :blocked, detail: @oauth, session_id: "s"})
    {card, run}
  end

  defp open(conn, board, card) do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}")
    render_async(view)
    view
  end

  test "the drawer shows Agent could not run, the cause, and Retry — no answer box", ctx do
    {card, _run} = blocked_park(ctx.board, ctx.flow)
    view = open(ctx.conn, ctx.board, card)

    assert has_element?(view, "#card-drawer-tab-panel-detail #needs-input-panel", "AGENT COULD NOT RUN")
    assert has_element?(view, "#needs-input-infrastructure", "Agent could not run")
    assert has_element?(view, "#needs-input-failure-detail", "OAuth session expired")
    assert has_element?(view, "#needs-input-retry", "Retry brainstorm")

    refute has_element?(view, "#needs-input-answer")
    refute has_element?(view, "#needs-input-form")
    refute has_element?(view, "#needs-input-panel textarea")
    refute view |> element("#needs-input-panel") |> render() =~ "attempt"

    # the blocked strip names it too (RE279 reads the same park kind)
    assert render(view) =~ "BRAINSTORM COULD NOT RUN"
  end

  test "Retry revives the run on the same node and unblocks the card", ctx do
    {card, run} = blocked_park(ctx.board, ctx.flow)
    view = open(ctx.conn, ctx.board, card)

    view |> element("#needs-input-retry") |> render_click()

    assert %{status: :running, current_node: "brainstorm"} = Runs.get_run!(run.id)
    assert Cards.get_card(ctx.board, card.id).status == :working
    assert_receive {:dispatched, %NodeJob{node_key: "brainstorm", payload: payload}}
    assert payload["resume_session"] == nil
  end
end
