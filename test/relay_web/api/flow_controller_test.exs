defmodule RelayWeb.Api.FlowControllerTest do
  @moduledoc "RLY-241: pull a flow, push it back, and the ways a push is refused."
  use RelayWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Relay.Boards
  alias Relay.Flows
  alias Relay.Repo
  alias Schemas.FlowVersion

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, board} = Boards.create_board(user, %{name: "Flow API board"})
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, user)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> token), board: board}
  end

  defp pull(conn, key), do: conn |> get(~p"/api/flows/#{key}") |> json_response(200) |> Map.fetch!("data")

  # A map body on a test PUT lands in `conn.body_params` verbatim (Plug's test adapter), which
  # is exactly what the controller reads — so the body/path `key` disagreement is visible here.
  # Named push_doc/3, not push/3: Plug.Conn already exports an HTTP/2 push/3 that ConnCase
  # imports, and a local push/3 here would conflict with it.
  defp push_doc(conn, key, doc), do: put(conn, ~p"/api/flows/#{key}", doc)

  defp version_rows(board, key) do
    flow = Flows.get_flow!(board, key)
    Repo.aggregate(from(v in FlowVersion, where: v.flow_id == ^flow.id), :count)
  end

  describe "GET /api/flows" do
    test "returns every flow on the board, fully serialized, in key order", %{conn: conn} do
      data = conn |> get(~p"/api/flows") |> json_response(200) |> Map.fetch!("data")

      assert Enum.map(data, & &1["key"]) == ["code", "plan", "spec"]
      code = Enum.find(data, &(&1["key"] == "code"))
      assert is_list(code["nodes"])
      assert code["trigger"]["pulls_from"] == "Plan:Done"
    end

    test "401s without a bearer token", %{conn: conn} do
      assert conn |> delete_req_header("authorization") |> get(~p"/api/flows") |> json_response(401)
    end
  end

  describe "GET /api/flows/:key" do
    test "returns the canonical document", %{conn: conn} do
      doc = pull(conn, "code")

      assert doc["key"] == "code"
      assert doc["version"] == 1
      assert doc["enabled"] == false
      assert doc["isolation"] == "exclusive"
      assert length(doc["nodes"]) == 18
      assert Enum.find(doc["nodes"], &(&1["key"] == "implement"))["expects_commits"] == true
    end

    test "404s an unknown key", %{conn: conn} do
      body = conn |> get(~p"/api/flows/nope") |> json_response(404)
      assert body["error"]["code"] == "not_found"
    end
  end

  describe "PUT /api/flows/:key" do
    test "an unchanged push is a no-op: same version, no new snapshot row", %{conn: conn, board: board} do
      doc = pull(conn, "spec")
      before_rows = version_rows(board, "spec")

      body = conn |> push_doc("spec", doc) |> json_response(200) |> Map.fetch!("data")

      assert body["version"] == doc["version"]
      assert version_rows(board, "spec") == before_rows
    end

    test "an edited push bumps the version and takes effect", %{conn: conn} do
      doc = pull(conn, "spec")

      edited =
        update_in(doc, ["nodes"], fn nodes ->
          Enum.map(nodes, fn n -> if n["key"] == "brainstorm", do: Map.put(n, "max_retries", 2), else: n end)
        end)

      body = conn |> push_doc("spec", edited) |> json_response(200) |> Map.fetch!("data")

      assert body["version"] == doc["version"] + 1
      assert Enum.find(body["nodes"], &(&1["key"] == "brainstorm"))["max_retries"] == 2
      assert pull(conn, "spec")["version"] == doc["version"] + 1
    end

    test "creating a flow that doesn't exist answers 201 at v1, disabled", %{conn: conn} do
      doc = %{
        "key" => "audit",
        "isolation" => "shared_clean",
        "trigger" => %{"pulls_from" => nil, "works_in" => nil, "lands_on" => nil},
        "nodes" => [%{"key" => "look", "type" => "agent", "run" => "/audit {ref}"}],
        "edges" => [
          %{"from" => "start", "to" => "look"},
          %{"from" => "look", "to" => "done", "on" => "succeeded"}
        ]
      }

      body = conn |> push_doc("audit", doc) |> json_response(201) |> Map.fetch!("data")

      assert body["key"] == "audit"
      assert body["version"] == 1
      assert body["enabled"] == false
    end

    test "a push can arm and disarm a flow", %{conn: conn, board: board} do
      doc = pull(conn, "spec")

      armed = conn |> push_doc("spec", Map.put(doc, "enabled", true)) |> json_response(200) |> Map.fetch!("data")
      assert armed["enabled"] == true
      assert Flows.get_flow!(board, "spec").enabled

      disarmed =
        conn
        |> push_doc("spec", Map.merge(doc, %{"enabled" => false, "version" => armed["version"]}))
        |> json_response(200)
        |> Map.fetch!("data")

      assert disarmed["enabled"] == false
      refute Flows.get_flow!(board, "spec").enabled
    end

    test "a document that omits `enabled` leaves a live flow armed", %{conn: conn, board: board} do
      {:ok, _} = Flows.enable_flow(Flows.get_flow!(board, "spec"))
      doc = pull(conn, "spec")

      body = conn |> push_doc("spec", Map.delete(doc, "enabled")) |> json_response(200) |> Map.fetch!("data")

      assert body["enabled"] == true
      assert Flows.get_flow!(board, "spec").enabled
    end

    test "a stale version is refused with 409 and changes nothing", %{conn: conn, board: board} do
      doc = pull(conn, "spec")

      first =
        update_in(doc, ["nodes"], fn nodes ->
          Enum.map(nodes, fn n -> if n["key"] == "brainstorm", do: Map.put(n, "run", "/brainstorm-a {ref}"), else: n end)
        end)

      assert conn |> push_doc("spec", first) |> json_response(200)

      stale =
        update_in(doc, ["nodes"], fn nodes ->
          Enum.map(nodes, fn n -> if n["key"] == "brainstorm", do: Map.put(n, "max_retries", 9), else: n end)
        end)

      body = conn |> push_doc("spec", stale) |> json_response(409)
      assert body["error"]["code"] == "stale_version"

      current = Flows.get_flow!(board, "spec")
      assert Enum.find(current.nodes, &(&1.key == "brainstorm")).run == "/brainstorm-a {ref}"
      assert Enum.find(current.nodes, &(&1.key == "brainstorm")).max_retries == 1
    end

    test "a version on a flow that doesn't exist is ignored, not a conflict", %{conn: conn} do
      doc = pull(conn, "spec")
      body = push_doc(conn, "brand-new", Map.merge(doc, %{"key" => "brand-new", "version" => 42}))
      assert json_response(body, 201)["data"]["version"] == 1
    end

    test "a key in the body disagreeing with the path is a 422 key_mismatch", %{conn: conn} do
      doc = pull(conn, "spec")
      body = conn |> push_doc("plan", doc) |> json_response(422)
      assert body["error"]["code"] == "key_mismatch"
    end

    test "an unresolvable trigger stage is a 422 naming it, and writes nothing", %{conn: conn, board: board} do
      doc = pull(conn, "plan")
      broken = put_in(doc, ["trigger", "lands_on"], "Nonexistent Stage")

      body = conn |> push_doc("plan", broken) |> json_response(422)

      assert body["error"]["code"] == "unknown_stages"
      assert body["error"]["message"] =~ "Nonexistent Stage"
      assert Flows.get_flow!(board, "plan").lands_on_stage_id
      assert pull(conn, "plan")["trigger"]["lands_on"] == "Plan:Done"
    end

    test "a malformed document is a 422 invalid_document naming the reason", %{conn: conn} do
      doc = pull(conn, "spec")
      body = conn |> push_doc("spec", Map.put(doc, "isolation", "sandboxed")) |> json_response(422)

      assert body["error"]["code"] == "invalid_document"
      assert body["error"]["message"] =~ "sandboxed"
    end

    test "an invalid graph is a 422 invalid from the shared changeset validation", %{conn: conn, board: board} do
      doc = pull(conn, "spec")
      dangling = put_in(doc, ["edges"], [%{"from" => "start", "to" => "ghost"}])

      body = conn |> push_doc("spec", dangling) |> json_response(422)

      assert body["error"]["code"] == "invalid"
      assert body["error"]["message"] =~ "ghost"
      assert Flows.get_flow!(board, "spec").version == 1
    end

    test "arming a flow whose pulls_from stage already has an enabled flow is a 422, and rolls the write back",
         %{conn: conn, board: board} do
      spec = Flows.get_flow!(board, "spec")
      {:ok, _} = Flows.enable_flow(spec)

      plan = pull(conn, "plan")

      colliding =
        plan
        |> put_in(["trigger", "pulls_from"], "Next up")
        |> Map.put("enabled", true)

      body = conn |> push_doc("plan", colliding) |> json_response(422)
      assert body["error"]["code"] == "invalid"

      # The whole push rolled back: plan is still disabled AND still pulls from its own stage.
      reread = Flows.get_flow!(board, "plan")
      refute reread.enabled
      refute reread.pulls_from_stage_id == spec.pulls_from_stage_id
      assert pull(conn, "plan")["trigger"]["pulls_from"] == "Spec:Done"
    end

    test "401s without a bearer token", %{conn: conn} do
      assert conn
             |> delete_req_header("authorization")
             |> put(~p"/api/flows/spec", %{})
             |> json_response(401)
    end
  end
end
