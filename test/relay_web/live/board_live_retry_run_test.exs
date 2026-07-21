defmodule RelayWeb.BoardLiveRetryRunTest do
  use RelayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Relay.Cards
  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeJob

  setup :register_and_log_in_user

  setup %{user: user} do
    FakeDispatcher.register(self())
    board = Relay.Boards.get_or_create_default_board(user)
    flow = dead_end_flow(board)
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Cards.create_card(stage, %{title: "Retry from the board"})
    start_supervised!(Relay.Runs.Supervisor)
    %{board: board, flow: flow, card: card}
  end

  # RLY-194 gave the seeded "spec" flow's brainstorm a :failed → needs_input park edge, so
  # it no longer dead-ends a run on hard failure — it parks instead. This suite is about the
  # generic failed-run-offers-Retry banner behavior, not that library flow specifically, so
  # it uses a custom flow shaped like the pre-RLY-194 "spec" flow: a single "brainstorm" node
  # with max_retries: 1 and no :failed edge at all, so two failures still end the run :failed.
  defp dead_end_flow(board) do
    next_up = Enum.find(board.stages, &(&1.name == "Next up"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    review = Enum.find(board.stages, &(&1.name == "Spec:Review"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "dead-end",
        isolation: :shared_clean,
        pulls_from_stage_id: next_up.id,
        works_in_stage_id: spec.id,
        lands_on_stage_id: review.id,
        nodes: [%{key: "brainstorm", type: :agent, run: "/brainstorm {ref}", max_retries: 1}],
        edges: [%{from: "start", to: "brainstorm"}, %{from: "brainstorm", to: "done", on: :succeeded}]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  defp failed_run(card, flow) do
    {:ok, _run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{} = first}
    {:ok, _run} = Runs.report_outcome(first, %{outcome: :failed, detail: "first boom"})
    assert_receive {:dispatched, %NodeJob{} = second}
    {:ok, run} = Runs.report_outcome(second, %{outcome: :failed, detail: "final boom"})
    Runs.get_run!(run.id)
  end

  defp open(conn, board, card) do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}")
    render_async(view)
    view
  end

  test "a failed run's banner offers Retry", ctx do
    _run = failed_run(ctx.card, ctx.flow)
    view = open(ctx.conn, ctx.board, ctx.card)

    assert has_element?(view, "#run-retry")
  end

  test "a running run's banner does not", ctx do
    {:ok, _run} = Runs.start_run(ctx.card, ctx.flow)
    assert_receive {:dispatched, %NodeJob{}}
    view = open(ctx.conn, ctx.board, ctx.card)

    refute has_element?(view, "#run-retry")
  end

  test "clicking it makes the run live from the failed node", ctx do
    run = failed_run(ctx.card, ctx.flow)
    view = open(ctx.conn, ctx.board, ctx.card)

    view |> element("#run-retry") |> render_click()

    assert Runs.get_run!(run.id).status == :running
    assert Runs.get_run!(run.id).current_node == "brainstorm"
    assert_receive {:dispatched, %NodeJob{node_key: "brainstorm"}}
    refute has_element?(view, "#run-retry")
  end

  test "a refusal surfaces as a flash and leaves the run alone", ctx do
    run = failed_run(ctx.card, ctx.flow)
    view = open(ctx.conn, ctx.board, ctx.card)

    # Break the retry between render and click: a second active run makes it refuse.
    insert(:run, card: Cards.get_card(ctx.board, ctx.card.id), status: :running)

    html = view |> element("#run-retry") |> render_click()

    assert html =~ "already has an active run"
    assert Runs.get_run!(run.id).status == :failed
  end
end
