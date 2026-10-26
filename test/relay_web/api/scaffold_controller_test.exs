defmodule RelayWeb.Api.ScaffoldControllerTest do
  @moduledoc """
  RE304. `/api/scaffold` is how a project with **no board key** gets `./relay` and the three
  `relay-*` skills, so "reachable unauthenticated" is the contract here, not an oversight —
  the board's install script fetches them before anything has authenticated. The glob route
  serves manifest entries only.
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

  test "the manifest needs no board key — the install script fetches it before one is used", %{conn: conn} do
    assert conn |> get(~p"/api/scaffold") |> json_response(200)

    assert conn
           |> put_req_header("authorization", "Bearer not-a-real-key")
           |> get(~p"/api/scaffold")
           |> json_response(200)
  end

  # RE443: the served ./relay carries this board's URL, so a project needs no RELAY_URL.
  test "the runner is served unauthenticated with this board's URL baked in", %{conn: conn} do
    body = conn |> get("/api/scaffold/relay") |> response(200)
    url = RelayWeb.Endpoint.url()

    assert body =~ ~r/^#{Regex.escape(~s(BOARD_URL = "#{url}"))}$/m
    assert String.starts_with?(body, "#!")
    assert body =~ "RUNNER_VERSION"

    {:ok, placeholder} = Scaffold.fetch("relay")
    assert String.replace(body, ~s(BOARD_URL = "#{url}"), ~s(BOARD_URL = "")) == placeholder
  end

  # RE480 scenario 3: the old production host as request host never reaches the runner or
  # the manifest.
  test "the baked BOARD_URL follows the configured host, not the request's", %{conn: conn} do
    conn = %{conn | host: "relayboard.fly.dev"}
    body = conn |> get("/api/scaffold/relay") |> response(200)

    assert body =~ ~r/^#{Regex.escape(~s(BOARD_URL = "#{RelayWeb.Endpoint.url()}"))}$/m
    refute body =~ "relayboard.fly.dev"

    manifest = conn |> get(~p"/api/scaffold") |> response(200)
    refute manifest =~ "relayboard.fly.dev"
  end

  # RE443 review: every runner up to v89 checks a downloaded body with a RAW
  # `sha256(body) == item["sha256"]` and refuses to write it otherwise. The manifest's `sha256`
  # must therefore be the sha of the bytes this board actually serves — the baked copy — or no
  # installed runner can `./relay update` itself. v90+ compares `unbaked_sha256` instead.
  test "the manifest's runner sha256 is the sha of the served (baked) bytes", %{conn: conn} do
    body = conn |> get("/api/scaffold/relay") |> response(200)
    {:ok, placeholder} = Scaffold.fetch("relay")

    item = conn |> get(~p"/api/scaffold") |> json_response(200) |> runner_item()

    assert item["sha256"] == sha256(body)
    assert item["bytes"] == byte_size(body)
    assert item["unbaked_sha256"] == sha256(placeholder)
  end

  test "only the runner carries an unbaked_sha256; every other item is served as built",
       %{conn: conn} do
    %{"items" => items} = conn |> get(~p"/api/scaffold") |> json_response(200)

    for item <- items, item["path"] != "relay" do
      refute Map.has_key?(item, "unbaked_sha256")
      body = conn |> get("/api/scaffold/#{item["path"]}") |> response(200)
      assert item["sha256"] == sha256(body)
    end
  end

  # The version is derived from the BUILT (unbaked) shas, so it is the same on every board
  # serving one build and never moves with the endpoint URL.
  test "the version is the build's, independent of the baked URL", %{conn: conn} do
    {:ok, built} = Scaffold.manifest()

    assert %{"version" => version} = conn |> get(~p"/api/scaffold") |> json_response(200)
    assert version == built["version"]
    assert version == Scaffold.version(Enum.map(built["items"], &{&1["path"], &1["sha256"]}))
  end

  defp runner_item(%{"items" => items}), do: Enum.find(items, &(&1["path"] == "relay"))

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  test "the retired relay-setup skill is not served, and the manifest has five items",
       %{conn: conn} do
    assert %{"error" => %{"code" => "not_found"}} =
             conn |> get("/api/scaffold/.claude/skills/relay-setup/SKILL.md") |> json_response(404)

    assert %{"items" => items} = conn |> get(~p"/api/scaffold") |> json_response(200)
    assert length(items) == 5
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

  # ./relay's api() reads `["error"]["message"]`; a flat string `error` raises TypeError
  # there and the operator sees a bare "HTTP 404" instead of what the controller wrote.
  test "errors use the API's nested envelope, like every other /api route", %{conn: conn} do
    assert %{"error" => %{"code" => "not_found", "message" => message}} =
             conn |> get("/api/scaffold/nope") |> json_response(404)

    assert is_binary(message)
  end
end
