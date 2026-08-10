defmodule RelayWeb.Api.ScaffoldControllerTest do
  @moduledoc """
  RE304. `/api/scaffold` is how a project with **no board key** gets `bin/relay` and the four
  `relay-*` skills, so "reachable unauthenticated" is the contract here, not an oversight —
  `/relay-setup` runs before a key exists. The glob route serves manifest entries only.
  """
  use RelayWeb.ConnCase, async: true

  alias Relay.Scaffold

  test "the manifest is JSON and names exactly the Relay-owned items", %{conn: conn} do
    conn = get(conn, ~p"/api/scaffold")

    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    body = json_response(conn, 200)

    assert body["version"] =~ ~r/\A[0-9a-f]{12}\z/
    assert Enum.map(body["items"], & &1["path"]) == Scaffold.items()

    for item <- body["items"] do
      assert item["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
      assert is_integer(item["bytes"]) and item["bytes"] > 0
    end
  end

  test "the manifest needs no board key — /relay-setup runs before one exists", %{conn: conn} do
    assert conn |> get(~p"/api/scaffold") |> json_response(200)

    assert conn
           |> put_req_header("authorization", "Bearer not-a-real-key")
           |> get(~p"/api/scaffold")
           |> json_response(200)
  end

  test "the executor is served byte-for-byte, unauthenticated", %{conn: conn} do
    body = conn |> get("/api/scaffold/bin/relay") |> response(200)

    assert {:ok, ^body} = Scaffold.fetch("bin/relay")
    assert String.starts_with?(body, "#!")
    assert body =~ "EXECUTOR_VERSION"
  end

  test "a nested skill path is served", %{conn: conn} do
    body = conn |> get("/api/scaffold/.claude/skills/relay-update/SKILL.md") |> response(200)

    assert body =~ "name: relay-update"
  end

  test "a path outside the manifest is 404 — this is not a file server", %{conn: conn} do
    for path <- ["/api/scaffold/mix.exs", "/api/scaffold/lib/relay.ex", "/api/scaffold/nope"] do
      assert conn |> get(path) |> json_response(404)
    end
  end
end
