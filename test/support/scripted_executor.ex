defmodule Relay.Runs.Scheduler.ScriptedExecutor do
  @moduledoc """
  A test-only executor that speaks ONLY board-key HTTP (Phoenix.ConnTest) — the
  exact surface a real `relay execute` uses — so the E2E test drives the whole
  system with no `Relay.Runs` context calls and no `claude`. Each function takes
  an authed `conn` (board-key bearer) and returns the decoded response.
  """
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint RelayWeb.Endpoint

  @doc "Advertise capacity + liveness. Feeds Relay.Runs.Capacity via the heartbeat branch."
  def heartbeat(conn, name, capacity) do
    conn
    |> post("/api/board/heartbeat", %{
      "name" => name,
      "host" => "scripted",
      "interval" => 30,
      "capacity" => capacity
    })
    |> json_response(200)
  end

  @doc "Claim the next job. Returns the decoded payload map, or nil on 204 (nothing claimable)."
  def claim(conn, name, capacity) do
    conn =
      post(conn, "/api/node-jobs/claim?wait=0", %{
        "executor" => %{"name" => name, "host" => "scripted", "interval" => 30},
        "capacity" => capacity
      })

    case conn.status do
      200 -> json_response(conn, 200)
      204 -> nil
    end
  end

  @doc "Post a batch of log lines attributed to the claimed job (node_job_id → run)."
  def log(conn, ref, node_job_id, lines) do
    entries = Enum.map(lines, &%{"ref" => ref, "text" => &1, "node_job_id" => to_string(node_job_id)})

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/board/logs", Jason.encode!(entries))
    |> response(200)
  end

  @doc "Simulate the skill asking a structured question batch (blocks the card)."
  def needs_input(conn, ref, questions) do
    conn
    |> post("/api/cards/#{ref}/needs-input", %{"questions" => questions})
    |> json_response(200)
  end

  @doc "Report a node-job outcome."
  def outcome(conn, node_job_id, attrs) do
    conn
    |> post("/api/node-jobs/#{node_job_id}/outcome", attrs)
    |> json_response(200)
  end
end
