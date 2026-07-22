defmodule RelayWeb.Api.RestartStalledTest do
  use RelayWeb.ConnCase, async: false

  alias Relay.Cards
  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeJob

  setup %{conn: conn} do
    Relay.Runs.Capacity.reset()
    FakeDispatcher.register(self())

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Restart API Board"})
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, user)
    flow = park_flow(board)
    start_supervised!(Relay.Runs.Supervisor)

    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board, flow: flow}
  end

  defp park_flow(board) do
    next_up = Enum.find(board.stages, &(&1.name == "Next up"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    review = Enum.find(board.stages, &(&1.name == "Spec:Review"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "park-flow",
        isolation: :shared_clean,
        pulls_from_stage_id: next_up.id,
        works_in_stage_id: spec.id,
        lands_on_stage_id: review.id,
        nodes: [%{key: "brainstorm", type: :agent, run: "/brainstorm {ref}"}],
        edges: [
          %{from: "start", to: "brainstorm"},
          %{from: "brainstorm", to: "done", on: :succeeded},
          %{from: "brainstorm", to: "needs_input", on: :failed}
        ]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  defp park(board, flow, title, outcome) do
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Cards.create_card(stage, %{title: title})
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{} = job}
    {:ok, _run} = Runs.report_outcome(job, %{outcome: outcome, detail: "x", session_id: "s"})
    {card, run}
  end

  test "POST /api/board/restart-stalled revives the stalled runs and reports the count", ctx do
    {_c1, died} = park(ctx.board, ctx.flow, "Died", :failed)
    {_c2, ask} = park(ctx.board, ctx.flow, "Asked", :needs_input)

    body =
      ctx.conn
      |> post(~p"/api/board/restart-stalled", %{})
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["status"] == "ok"
    assert body["restarted"] == 1
    assert Runs.get_run!(died.id).status == :running
    assert Runs.get_run!(ask.id).status == :parked
  end

  test "a genuine question refuses per-card retry with awaiting_answer (422)", ctx do
    {card, run} = park(ctx.board, ctx.flow, "Asked", :needs_input)
    ref = Cards.ref(ctx.board, card)

    body =
      ctx.conn
      |> post(~p"/api/cards/#{ref}/retry", %{})
      |> json_response(422)
      |> Map.fetch!("error")

    assert body["code"] == "awaiting_answer"
    assert body["message"] =~ "waiting on a human answer"
    assert Runs.get_run!(run.id).status == :parked
  end

  test "it requires a bearer token", _ctx do
    assert build_conn() |> post(~p"/api/board/restart-stalled", %{}) |> json_response(401)
  end
end
