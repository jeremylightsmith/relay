defmodule Relay.RunsInFlightSubTaskTest do
  use Relay.DataCase, async: true

  alias Relay.Repo
  alias Relay.Runs
  alias Schemas.Flow.Node

  setup do
    card = insert(:card)
    [a, b] = for position <- 1..2, do: insert(:sub_task, card: card, position: position)
    board = Repo.get!(Schemas.Board, card.board_id)
    %{card: card, board: board, a: a, b: b}
  end

  defp foreach_flow(board) do
    insert(:flow,
      board: board,
      nodes: [
        %Node{key: "impl", type: :agent, run: "impl {ref}", foreach: "card.tasks"},
        %Node{key: "review", type: :agent, run: "review {ref}"}
      ]
    )
  end

  defp plain_flow(board) do
    insert(:flow, board: board, nodes: [%Node{key: "spec", type: :agent, run: "spec {ref}"}])
  end

  defp run_on(card, flow, attrs \\ %{}) do
    insert(
      :run,
      Map.merge(%{card: card, flow_id: flow.id, flow_key: flow.key, status: :running, current_node: "impl"}, attrs)
    )
  end

  defp bind(run, node_key, sub_task) do
    insert(:node_execution, run: run, node_key: node_key, sub_task_id: sub_task && sub_task.id)
  end

  test "nil for a card with no run", %{card: card} do
    assert Runs.in_flight_sub_task_id(card) == nil
  end

  test "the foreach node's latest binding for an active running run", ctx do
    run = run_on(ctx.card, foreach_flow(ctx.board))
    bind(run, "impl", ctx.a)
    bind(run, "review", ctx.a)
    bind(run, "impl", ctx.b)

    assert Runs.in_flight_sub_task_id(ctx.card) == ctx.b.id
  end

  test "a parked run still has an in-flight task", ctx do
    run = run_on(ctx.card, foreach_flow(ctx.board), %{status: :parked, parked_reason: :needs_input})
    bind(run, "impl", ctx.b)

    assert Runs.in_flight_sub_task_id(ctx.card) == ctx.b.id
  end

  test "a bound task that is already done still counts as in flight", ctx do
    run = run_on(ctx.card, foreach_flow(ctx.board))
    bind(run, "impl", ctx.b)
    Repo.update!(Ecto.Changeset.change(ctx.b, done: true))

    assert Runs.in_flight_sub_task_id(ctx.card) == ctx.b.id
  end

  test "nil for a terminal run", ctx do
    run = run_on(ctx.card, foreach_flow(ctx.board), %{status: :done, current_node: nil})
    bind(run, "impl", ctx.b)

    assert Runs.in_flight_sub_task_id(ctx.card) == nil
  end

  test "nil for an active run whose flow has no foreach node", ctx do
    run = run_on(ctx.card, plain_flow(ctx.board), %{current_node: "spec"})
    bind(run, "spec", nil)

    assert Runs.in_flight_sub_task_id(ctx.card) == nil
  end

  test "nil for an active run whose flow row is gone", ctx do
    run_on(ctx.card, foreach_flow(ctx.board), %{flow_id: nil})

    assert Runs.in_flight_sub_task_id(ctx.card) == nil
  end
end
