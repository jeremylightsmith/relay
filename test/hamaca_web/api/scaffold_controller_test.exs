defmodule HamacaWeb.Api.ScaffoldControllerTest do
  @moduledoc """
  RE304, RE478. `/api/scaffold` is how a project with **no board key** gets its runner and
  skills, so "reachable unauthenticated" is the contract here, not an oversight — the board's
  install script fetches them before anything has authenticated. The glob route serves
  manifest entries of the requested layout only.

  No `layout` param is the legacy layout — byte-for-byte what every v≤93 `./relay` has always
  been served. `?layout=hamaca` is the Hamaca-named layout.
  """
  use HamacaWeb.ConnCase, async: true

  alias Hamaca.Scaffold

  @legacy_items [
    ".claude/skills/relay-doctor/SKILL.md",
    ".claude/skills/relay-onboard/SKILL.md",
    ".claude/skills/relay-update/SKILL.md",
    "relay",
    "relay.md"
  ]

  @hamaca_items [
    ".claude/skills/hamaca-doctor/SKILL.md",
    ".claude/skills/hamaca-onboard/SKILL.md",
    ".claude/skills/hamaca-update/SKILL.md",
    ".claude/skills/relay-doctor/SKILL.md",
    ".claude/skills/relay-onboard/SKILL.md",
    ".claude/skills/relay-update/SKILL.md",
    "hamaca",
    "hamaca.md",
    "relay"
  ]

  # Scenario 9
  test "with no layout the manifest is today's five legacy items", %{conn: conn} do
    conn = get(conn, ~p"/api/scaffold")

    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    body = json_response(conn, 200)

    assert body["version"] =~ ~r/\A[0-9a-f]{12}\z/
    assert paths(body) == @legacy_items
    assert unbaked(body) == ["relay"]

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

  # Scenario 10 — RE443: the served ./relay carries this board's URL, so a project needs no
  # RELAY_URL; and every runner up to v89 checks the download with a RAW sha256 against the
  # manifest, so the manifest's sha must be the baked bytes'.
  test "with no layout the runner is relay, baked with this board's URL, sha matching the manifest",
       %{conn: conn} do
    body = conn |> get("/api/scaffold/relay") |> response(200)
    url = HamacaWeb.Endpoint.url()

    assert String.starts_with?(body, "#!")
    assert body =~ ~r/^RUNNER_VERSION = \d+$/m
    assert body =~ ~r/^#{Regex.escape(~s(BOARD_URL = "#{url}"))}$/m

    {:ok, placeholder} = Scaffold.fetch("relay")
    assert String.replace(body, ~s(BOARD_URL = "#{url}"), ~s(BOARD_URL = "")) == placeholder

    item = conn |> get(~p"/api/scaffold") |> json_response(200) |> item("relay")
    assert item["sha256"] == sha256(body)
    assert item["bytes"] == byte_size(body)
    assert item["unbaked_sha256"] == sha256(placeholder)
  end

  # RE480 scenario 3: the old production host as request host never reaches the runner or
  # the manifest.
  test "the baked BOARD_URL follows the configured host, not the request's", %{conn: conn} do
    conn = %{conn | host: "relayboard.fly.dev"}
    body = conn |> get("/api/scaffold/relay") |> response(200)

    assert body =~ ~r/^#{Regex.escape(~s(BOARD_URL = "#{HamacaWeb.Endpoint.url()}"))}$/m
    refute body =~ "relayboard.fly.dev"

    manifest = conn |> get(~p"/api/scaffold") |> response(200)
    refute manifest =~ "relayboard.fly.dev"
  end

  # Scenario 11
  test "?layout=hamaca is the nine hamaca items, only hamaca carrying unbaked_sha256", %{conn: conn} do
    body = conn |> get(~p"/api/scaffold?layout=hamaca") |> json_response(200)

    assert body["version"] =~ ~r/\A[0-9a-f]{12}\z/
    assert paths(body) == @hamaca_items
    assert unbaked(body) == ["hamaca"]
  end

  # Scenario 11
  test "?layout=hamaca serves the baked runner at hamaca, sha matching its item", %{conn: conn} do
    body = conn |> get("/api/scaffold/hamaca?layout=hamaca") |> response(200)
    url = HamacaWeb.Endpoint.url()

    assert body =~ ~r/^RUNNER_VERSION = \d+$/m
    assert body =~ ~r/^#{Regex.escape(~s(BOARD_URL = "#{url}"))}$/m

    {:ok, placeholder} = Scaffold.fetch("hamaca", layout: "hamaca")
    item = conn |> get(~p"/api/scaffold?layout=hamaca") |> json_response(200) |> item("hamaca")
    assert item["sha256"] == sha256(body)
    assert item["bytes"] == byte_size(body)
    assert item["unbaked_sha256"] == sha256(placeholder)
  end

  # Scenario 11
  test "?layout=hamaca serves the shim at relay — not a runner", %{conn: conn} do
    body = conn |> get("/api/scaffold/relay?layout=hamaca") |> response(200)

    assert String.starts_with?(body, "#!")
    refute body =~ ~r/^RUNNER_VERSION/m
  end

  test "every non-runner item of either layout is served exactly as built", %{conn: conn} do
    for layout <- Scaffold.layouts() do
      %{"items" => items} = conn |> get("/api/scaffold?layout=#{layout}") |> json_response(200)

      for item <- items, item["path"] != Scaffold.runner_path(layout) do
        refute Map.has_key?(item, "unbaked_sha256")
        body = conn |> get("/api/scaffold/#{item["path"]}?layout=#{layout}") |> response(200)
        assert item["sha256"] == sha256(body)
      end
    end
  end

  # The version is derived from the BUILT (unbaked) shas, so it is the same on every board
  # serving one build and never moves with the endpoint URL.
  test "each layout's version is the build's, independent of the baked URL", %{conn: conn} do
    for layout <- Scaffold.layouts() do
      {:ok, built} = Scaffold.manifest(layout: layout)

      assert %{"version" => version} = conn |> get("/api/scaffold?layout=#{layout}") |> json_response(200)
      assert version == built["version"]
      assert version == Scaffold.version(Enum.map(built["items"], &{&1["path"], &1["sha256"]}))
    end
  end

  # Scenario 12
  test "a path from the other layout is 404 not_found", %{conn: conn} do
    assert %{"error" => %{"code" => "not_found"}} =
             conn |> get("/api/scaffold/hamaca") |> json_response(404)

    assert %{"error" => %{"code" => "not_found"}} =
             conn |> get("/api/scaffold/relay.md?layout=hamaca") |> json_response(404)
  end

  # Scenario 12
  test "an unknown layout is 400 unknown_layout on both routes", %{conn: conn} do
    for path <- ["/api/scaffold?layout=bogus", "/api/scaffold/relay?layout=bogus"] do
      assert %{"error" => %{"code" => "unknown_layout", "message" => message}} =
               conn |> get(path) |> json_response(400)

      assert is_binary(message)
    end
  end

  test "the retired relay-setup skill is not served", %{conn: conn} do
    assert %{"error" => %{"code" => "not_found"}} =
             conn |> get("/api/scaffold/.claude/skills/relay-setup/SKILL.md") |> json_response(404)
  end

  test "a nested skill path is served — complete in legacy, an alias in hamaca", %{conn: conn} do
    legacy = conn |> get("/api/scaffold/.claude/skills/relay-update/SKILL.md") |> response(200)
    assert legacy =~ "name: relay-update"
    assert legacy =~ "./relay update"

    alias_skill =
      conn |> get("/api/scaffold/.claude/skills/relay-update/SKILL.md?layout=hamaca") |> response(200)

    assert alias_skill =~ "Renamed: use /hamaca-update."
  end

  test "a path outside the manifest is 404 — this is not a file server", %{conn: conn} do
    for path <- ["/api/scaffold/mix.exs", "/api/scaffold/lib/hamaca.ex", "/api/scaffold/nope"] do
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

  defp paths(%{"items" => items}), do: Enum.map(items, & &1["path"])

  defp unbaked(%{"items" => items}), do: for(%{"path" => p, "unbaked_sha256" => _} <- items, do: p)

  defp item(%{"items" => items}, path), do: Enum.find(items, &(&1["path"] == path))

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
