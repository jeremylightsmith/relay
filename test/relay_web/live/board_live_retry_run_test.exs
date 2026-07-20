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
    {:ok, flow} = board |> Relay.Flows.get_flow!("spec") |> Relay.Flows.enable_flow()
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Cards.create_card(stage, %{title: "Retry from the board"})
    start_supervised!(Relay.Runs.Supervisor)
    %{board: board, flow: flow, card: card}
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
