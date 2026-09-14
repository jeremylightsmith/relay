defmodule RelayWeb.Api.PreRenameRefusalTest do
  @moduledoc """
  RE319 — the hard cut's edges. The wire renamed its identity key from `executor` to `runner` with
  no alias, so a process started before the rename is refused — legibly, never served — and the
  old roster route is simply gone. This file and the controller's `pre_rename/1` are the only
  places the retired key is spelled.
  """
  use RelayWeb.ConnCase, async: true

  alias Relay.Runs

  @legacy_ident %{"name" => "old-box", "host" => "old.local", "interval" => 30, "version" => 62}

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn, board: board}
  end

  for route <- ["/api/node-jobs/claim?wait=0", "/api/node-jobs/heartbeat"] do
    test "POST #{route} with a pre-rename body is refused 409 runner_outdated and does no work",
         %{conn: conn, board: board} do
      body = %{"executor" => @legacy_ident, "capacity" => %{"shared_clean" => 1}, "running" => [], "held" => []}

      error = conn |> post(unquote(route), Jason.encode!(body)) |> json_response(409) |> Map.fetch!("error")

      assert error["code"] == contract_outdated_code()
      assert error["required"] == Runs.min_runner_version()
      assert error["running"] == 62

      assert error["message"] ==
               "this runner predates the executor→runner rename — install ./relay (relay update) " <>
                 "and restart it with ./relay start"

      assert Runs.list_runner_status(board) == []
    end
  end

  test "a body that carries `runner` is current, whatever else it carries", %{conn: conn, board: board} do
    body = %{
      "runner" => %{
        "name" => "new-box",
        "host" => "new.local",
        "interval" => 30,
        "version" => Runs.min_talk_runner_version()
      },
      "executor" => @legacy_ident,
      "capacity" => %{"shared_clean" => 1},
      "running" => [],
      "held" => []
    }

    assert conn |> post("/api/node-jobs/claim?wait=0", Jason.encode!(body)) |> response(204)
    assert [%{name: "new-box"}] = Runs.list_runner_status(board)
  end

  test "the old roster route is gone", %{conn: conn} do
    # Not `assert_error_sent/2`: an unmatched route raises `Phoenix.Router.NoRouteError`, which
    # `Phoenix.Endpoint.RenderErrors` deliberately does not re-raise (see
    # `RelayWeb.DocsController.NotFoundError`'s moduledoc), so that macro can never observe it.
    assert conn |> get("/api/executors") |> response(404)
    assert conn |> get("/api/runners") |> json_response(200) |> Map.has_key?("data")
  end

  # The code a pre-rename process gets is the SAME one a merely old runner gets, and both are
  # pinned by the contract fixture that ./relay's tests read.
  defp contract_outdated_code do
    "test/fixtures/runner_contract.json"
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["claim_refused", "outdated", "error", "code"])
  end
end
