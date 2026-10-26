defmodule HamacaWeb.Api.HarnessControllerTest do
  @moduledoc "RE433 — `GET /api/harnesses`: the board's harness definitions for the runner, plus their digest."
  use HamacaWeb.ConnCase, async: true

  setup %{conn: conn} do
    board = insert(:board)
    :ok = Hamaca.Agents.ensure_seeded!(board)
    {:ok, %{token: token}} = Hamaca.ApiKeys.create_key(board, board.owner)
    %{authed: put_req_header(conn, "authorization", "Bearer " <> token), board: board}
  end

  # Task 2 · Scenario 12
  test "lists the board's harnesses in wire shape with their digest", %{authed: conn, board: board} do
    body = conn |> get(~p"/api/harnesses") |> json_response(200)

    assert Enum.map(body["harnesses"], & &1["key"]) == ["claude-code", "codex", "gemini-cli"]

    for harness <- body["harnesses"] do
      assert harness |> Map.keys() |> Enum.sort() ==
               Enum.sort([
                 "key",
                 "name",
                 "command",
                 "models",
                 "resume_command",
                 "session_id_path",
                 "signed_in_check",
                 "usage"
               ])
    end

    # RE436 — each harness carries its usage rule in `Schemas.HarnessUsage.wire/1` shape.
    claude = Enum.find(body["harnesses"], &(&1["key"] == "claude-code"))
    assert claude["usage"]["source"] == "output"
    assert Enum.map(claude["usage"]["windows"], & &1["label"]) == ["5h", "7d"]

    assert body["digest"] == Hamaca.Agents.harnesses_digest(board)
  end

  # Task 2 · Scenario 12
  test "is refused without a board key", %{conn: conn} do
    assert conn |> get(~p"/api/harnesses") |> response(401)
  end
end
