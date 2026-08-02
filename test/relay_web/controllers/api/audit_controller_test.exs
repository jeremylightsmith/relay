defmodule RelayWeb.Api.AuditControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Schemas.Flow.Edge

  @finding_keys ~w(severity check flow_key node_key run_id summary evidence fix)

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board}
  end

  defp audit_flow(board) do
    insert(:flow,
      board: board,
      key: "code",
      nodes: [
        %Schemas.Flow.Node{key: "implement", type: :agent},
        %Schemas.Flow.Node{key: "spec_review", type: :agent}
      ],
      edges: [
        %Edge{from: "start", to: "implement"},
        %Edge{from: "spec_review", to: "implement", on: :failed}
      ]
    )
  end

  # node_executions.sub_task_id is a real foreign key to sub_tasks (nilify_all on delete), so the
  # findings-dropped shape needs two persisted sub_task rows, not bare literals — the same
  # correction Relay.Runs.Audit's own tests make.
  defp run_with_dropped_findings(board) do
    card = insert(:card, board: board, stage: insert(:stage, board: board))
    run = insert(:run, card: card, flow_key: "code", status: :done)
    sub_a = insert(:sub_task, card: card).id
    sub_b = insert(:sub_task, card: card).id
    insert(:node_execution, run: run, node: "spec_review", outcome: :failed, sub_task_id: sub_a)
    insert(:node_execution, run: run, node: "implement", outcome: :succeeded, sub_task_id: sub_b)
    run
  end

  test "serves findings with the documented keys", %{conn: conn, board: board} do
    audit_flow(board)
    run = run_with_dropped_findings(board)

    data = conn |> get(~p"/api/flows/code/audit") |> json_response(200) |> Map.fetch!("data")

    assert data["flow_key"] == "code"
    assert data["window"] == Relay.Runs.default_window()
    assert data["runs"] == 1
    assert [finding] = data["findings"]
    assert Enum.sort(Map.keys(finding)) == Enum.sort(@finding_keys)
    assert finding["severity"] == "error"
    assert finding["check"] == "findings_dropped"
    assert finding["node_key"] == "spec_review"
    assert finding["run_id"] == run.id
  end

  test "honors an explicit window and echoes it", %{conn: conn, board: board} do
    audit_flow(board)

    data = conn |> get(~p"/api/flows/code/audit?window=all") |> json_response(200) |> Map.fetch!("data")

    assert data["window"] == "all"
    assert data["findings"] == []
    assert data["runs"] == 0
  end

  test "falls back to the default window on garbage", %{conn: conn, board: board} do
    audit_flow(board)

    data = conn |> get(~p"/api/flows/code/audit?window=nonsense") |> json_response(200) |> Map.fetch!("data")

    assert data["window"] == Relay.Runs.default_window()
  end

  test "404s an unknown flow key", %{conn: conn} do
    assert conn |> get(~p"/api/flows/nope/audit") |> json_response(404)
  end
end
