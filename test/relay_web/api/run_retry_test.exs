defmodule RelayWeb.Api.RunRetryTest do
  use RelayWeb.ConnCase, async: false

  alias Relay.Cards
  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeJob

  setup %{conn: conn} do
    Relay.Runs.Capacity.reset()
    FakeDispatcher.register(self())

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "API Retry Board"})
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, user)
    flow = dead_end_flow(board)
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Cards.create_card(stage, %{title: "Retry me"})
    start_supervised!(Relay.Runs.Supervisor)

    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board, flow: flow, card: card}
  end

  # RLY-194 gave the seeded "spec" flow's brainstorm a :failed → needs_input park edge, so
  # it no longer dead-ends a run on hard failure — it parks instead. This suite is about the
  # generic retry-a-failed-run API, not that library flow specifically, so it uses a custom
  # flow shaped like the pre-RLY-194 "spec" flow: a single "brainstorm" node with
  # max_retries: 1 and no :failed edge at all, so two failures still end the run :failed.
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

  test "POST /api/runs/:id/retry revives the run", ctx do
    run = failed_run(ctx.card, ctx.flow)

    body = ctx.conn |> post(~p"/api/runs/#{run.id}/retry", %{}) |> json_response(200) |> Map.fetch!("data")

    assert body["status"] == "ok"
    assert body["run_id"] == run.id
    assert body["node"] == "brainstorm"
    assert body["retries"] == 1
  end

  test "POST /api/cards/:ref/retry resolves the card's newest run", ctx do
    run = failed_run(ctx.card, ctx.flow)
    ref = Cards.ref(ctx.board, ctx.card)

    body = ctx.conn |> post(~p"/api/cards/#{ref}/retry", %{}) |> json_response(200) |> Map.fetch!("data")
    assert body["run_id"] == run.id
  end

  test "an `at` body targets that node", ctx do
    run = failed_run(ctx.card, ctx.flow)

    body =
      ctx.conn
      |> post(~p"/api/runs/#{run.id}/retry", %{"at" => "brainstorm"})
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["node"] == "brainstorm"
  end

  test "an unknown node is 422 with a message naming it", ctx do
    run = failed_run(ctx.card, ctx.flow)

    body =
      ctx.conn
      |> post(~p"/api/runs/#{run.id}/retry", %{"at" => "not_a_node"})
      |> json_response(422)
      |> Map.fetch!("error")

    assert body["code"] == "unknown_node"
    assert body["message"] =~ "not_a_node"
    assert Runs.get_run!(run.id).status == :failed
  end

  test "a non-string at is 422, not a 500", ctx do
    run = failed_run(ctx.card, ctx.flow)

    for at <- [5, true, ["brainstorm"], %{"key" => "brainstorm"}] do
      body =
        ctx.conn
        |> post(~p"/api/runs/#{run.id}/retry", %{"at" => at})
        |> json_response(422)
        |> Map.fetch!("error")

      assert body["code"] == "unknown_node"
      assert Runs.get_run!(run.id).status == :failed
    end
  end

  test "a running run is 422 naming its status", ctx do
    {:ok, run} = Runs.start_run(ctx.card, ctx.flow)
    assert_receive {:dispatched, %NodeJob{}}

    body = ctx.conn |> post(~p"/api/runs/#{run.id}/retry", %{}) |> json_response(422) |> Map.fetch!("error")
    assert body["code"] == "not_failed"
    assert body["message"] =~ "running"
  end

  test "an unknown run id is 404", ctx do
    assert ctx.conn |> post(~p"/api/runs/999999/retry", %{}) |> json_response(404)
  end

  test "a card with no runs is 404", ctx do
    stage = Enum.find(ctx.board.stages, &(&1.name == "Next up"))
    {:ok, other} = Cards.create_card(stage, %{title: "Never ran"})
    ref = Cards.ref(ctx.board, other)

    assert ctx.conn |> post(~p"/api/cards/#{ref}/retry", %{}) |> json_response(404)
  end

  test "another board's run is 404, not someone else's run revived", ctx do
    other_user = insert(:user)
    {:ok, other_board} = Relay.Boards.create_board(other_user, %{name: "Someone else"})
    other_card = insert(:card, board: other_board, stage: hd(other_board.stages))
    other_run = insert(:run, card: other_card, status: :failed)

    assert ctx.conn |> post(~p"/api/runs/#{other_run.id}/retry", %{}) |> json_response(404)
  end

  test "it requires a bearer token", %{card: card, flow: flow} do
    run = failed_run(card, flow)

    assert build_conn() |> post(~p"/api/runs/#{run.id}/retry", %{}) |> json_response(401)
  end
end
