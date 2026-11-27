defmodule HamacaWeb.Api.ScaffoldControllerTest do
  @moduledoc """
  RE304, RE478, RE482. `/api/scaffold` is how a project with **no board key** gets its runner
  and skills, so "reachable unauthenticated" is the contract here, not an oversight — the
  board's install script fetches them before anything has authenticated. The glob route serves
  manifest entries of the requested layout only.

  RE482 retired the legacy layout: `?layout=hamaca` is the one served layout, and a request
  with no `layout` param (or `layout=legacy`) — which only a v≤93 `./relay` auto-updating can
  send — is a 410 `runner_renamed` naming the install one-liner.
  """
  use HamacaWeb.ConnCase, async: true

  alias Hamaca.Scaffold
  alias Hamaca.Setup

  @hamaca_items [
    ".claude/skills/hamaca-doctor/SKILL.md",
    ".claude/skills/hamaca-onboard/SKILL.md",
    ".claude/skills/hamaca-update/SKILL.md",
    "hamaca",
    "hamaca.md"
  ]

  describe "the retired legacy layout (RE482)" do
    # Scenario 1
    test "no layout param is 410 runner_renamed naming the install one-liner", %{conn: conn} do
      assert %{"error" => %{"code" => "runner_renamed", "message" => message}} =
               conn |> get(~p"/api/scaffold") |> json_response(410)

      assert message =~ Setup.install_command(HamacaWeb.Endpoint.url(), "<your-board>")
      assert message =~ "./hamaca start"
    end

    # Scenario 2
    test "layout=legacy, and a file request with no layout, are 410 runner_renamed", %{conn: conn} do
      for path <- ["/api/scaffold?layout=legacy", "/api/scaffold/relay"] do
        assert %{"error" => %{"code" => "runner_renamed"}} = conn |> get(path) |> json_response(410)
      end
    end

    test "the 410 needs no board key either — an old runner sends none", %{conn: conn} do
      assert conn
             |> put_req_header("authorization", "Bearer not-a-real-key")
             |> get(~p"/api/scaffold")
             |> json_response(410)
    end
  end

  # Scenario 3
  test "?layout=hamaca is the five hamaca items, only hamaca carrying unbaked_sha256", %{conn: conn} do
    conn = get(conn, ~p"/api/scaffold?layout=hamaca")

    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    body = json_response(conn, 200)

    assert body["version"] =~ ~r/\A[0-9a-f]{12}\z/
    assert paths(body) == @hamaca_items
    refute Enum.any?(paths(body), &(&1 == "relay" or String.starts_with?(&1, ".claude/skills/relay-")))
    assert unbaked(body) == ["hamaca"]

    for item <- body["items"] do
      assert item["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
      assert is_integer(item["bytes"]) and item["bytes"] > 0
    end
  end

  test "the manifest needs no board key — the install script fetches it before one is used", %{conn: conn} do
    assert conn |> get(~p"/api/scaffold?layout=hamaca") |> json_response(200)

    assert conn
           |> put_req_header("authorization", "Bearer not-a-real-key")
           |> get(~p"/api/scaffold?layout=hamaca")
           |> json_response(200)
  end

  # RE443: the served runner carries this board's URL, so a project needs no HAMACA_URL; and
  # the manifest's sha must be the baked bytes'.
  test "?layout=hamaca serves the baked runner at hamaca, sha matching its item", %{conn: conn} do
    body = conn |> get("/api/scaffold/hamaca?layout=hamaca") |> response(200)
    url = HamacaWeb.Endpoint.url()

    assert String.starts_with?(body, "#!")
    assert body =~ ~r/^RUNNER_VERSION = \d+$/m
    assert body =~ ~r/^#{Regex.escape(~s(BOARD_URL = "#{url}"))}$/m

    {:ok, placeholder} = Scaffold.fetch("hamaca")
    assert String.replace(body, ~s(BOARD_URL = "#{url}"), ~s(BOARD_URL = "")) == placeholder

    item = conn |> get(~p"/api/scaffold?layout=hamaca") |> json_response(200) |> item("hamaca")
    assert item["sha256"] == sha256(body)
    assert item["bytes"] == byte_size(body)
    assert item["unbaked_sha256"] == sha256(placeholder)
  end

  # RE480 scenario 3: the old production host as request host never reaches the runner or
  # the manifest.
  test "the baked BOARD_URL follows the configured host, not the request's", %{conn: conn} do
    conn = %{conn | host: "relayboard.fly.dev"}
    body = conn |> get("/api/scaffold/hamaca?layout=hamaca") |> response(200)

    assert body =~ ~r/^#{Regex.escape(~s(BOARD_URL = "#{HamacaWeb.Endpoint.url()}"))}$/m
    refute body =~ "relayboard.fly.dev"

    manifest = conn |> get(~p"/api/scaffold?layout=hamaca") |> response(200)
    refute manifest =~ "relayboard.fly.dev"
  end

  test "every non-runner item is served exactly as built", %{conn: conn} do
    %{"items" => items} = conn |> get(~p"/api/scaffold?layout=hamaca") |> json_response(200)

    for item <- items, item["path"] != Scaffold.runner_path("hamaca") do
      refute Map.has_key?(item, "unbaked_sha256")
      body = conn |> get("/api/scaffold/#{item["path"]}?layout=hamaca") |> response(200)
      assert item["sha256"] == sha256(body)
    end
  end

  # The version is derived from the BUILT (unbaked) shas, so it is the same on every board
  # serving one build and never moves with the endpoint URL.
  test "the version is the build's, independent of the baked URL", %{conn: conn} do
    {:ok, built} = Scaffold.manifest()

    assert %{"version" => version} = conn |> get(~p"/api/scaffold?layout=hamaca") |> json_response(200)
    assert version == built["version"]
    assert version == Scaffold.version(Enum.map(built["items"], &{&1["path"], &1["sha256"]}))
  end

  # Scenario 4
  test "the retired relay shim is 404 not_found in the hamaca layout", %{conn: conn} do
    assert %{"error" => %{"code" => "not_found"}} =
             conn |> get("/api/scaffold/relay?layout=hamaca") |> json_response(404)

    for path <- [
          "/api/scaffold/relay.md?layout=hamaca",
          "/api/scaffold/.claude/skills/relay-update/SKILL.md?layout=hamaca"
        ] do
      assert %{"error" => %{"code" => "not_found"}} = conn |> get(path) |> json_response(404)
    end
  end

  # Scenario 5
  test "an unknown layout is 400 unknown_layout on both routes, listing only hamaca", %{conn: conn} do
    for path <- ["/api/scaffold?layout=bogus", "/api/scaffold/hamaca?layout=bogus"] do
      assert %{"error" => %{"code" => "unknown_layout", "message" => message}} =
               conn |> get(path) |> json_response(400)

      assert message == "layout must be one of: hamaca"
    end
  end

  test "the retired relay-setup skill is not served", %{conn: conn} do
    assert %{"error" => %{"code" => "not_found"}} =
             conn |> get("/api/scaffold/.claude/skills/relay-setup/SKILL.md?layout=hamaca") |> json_response(404)
  end

  test "a nested skill path is served", %{conn: conn} do
    skill = conn |> get("/api/scaffold/.claude/skills/hamaca-update/SKILL.md?layout=hamaca") |> response(200)
    assert skill =~ "name: hamaca-update"
  end

  test "a path outside the manifest is 404 — this is not a file server", %{conn: conn} do
    for path <- ["/api/scaffold/mix.exs", "/api/scaffold/lib/hamaca.ex", "/api/scaffold/nope"] do
      assert conn |> get(path <> "?layout=hamaca") |> json_response(404)
    end
  end

  # The runner's api() reads `["error"]["message"]`; a flat string `error` raises TypeError
  # there and the operator sees a bare "HTTP 404" instead of what the controller wrote.
  test "errors use the API's nested envelope, like every other /api route", %{conn: conn} do
    assert %{"error" => %{"code" => "not_found", "message" => message}} =
             conn |> get("/api/scaffold/nope?layout=hamaca") |> json_response(404)

    assert is_binary(message)
  end

  defp paths(%{"items" => items}), do: Enum.map(items, & &1["path"])

  defp unbaked(%{"items" => items}), do: for(%{"path" => p, "unbaked_sha256" => _} <- items, do: p)

  defp item(%{"items" => items}, path), do: Enum.find(items, &(&1["path"] == path))

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
