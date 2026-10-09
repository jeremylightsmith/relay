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
      assert code["trigger"] == %{"stage" => "Code"}
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
      assert length(doc["nodes"]) == 21
      assert Enum.find(doc["nodes"], &(&1["key"] == "implement"))["expects_commits"] == true
    end

    test "404s an unknown key", %{conn: conn} do
      body = conn |> get(~p"/api/flows/nope") |> json_response(404)
      assert body["error"]["code"] == "not_found"
    end
  end

  describe "PUT /api/flows/:key" do
    test "a push spelled with the legacy sub_tasks names saves and pulls back canonical (RE367)", %{conn: conn} do
      legacy =
        conn
        |> pull("code")
        |> Map.delete("version")
        |> Map.put("key", "legacy-code")
        # A stage holds one flow (RE429): `code` already sits on Code, so the copy goes on Deploy.
        |> Map.put("trigger", %{"stage" => "Deploy"})
        |> Jason.encode!()
        |> String.replace("card.tasks", "card.sub_tasks")
        |> String.replace(~s("tasks"), ~s("sub_tasks"))
        |> String.replace("{task_id}", "{sub_task_id}")
        |> String.replace("{task}", "{sub_task}")
        |> Jason.decode!()

      assert Jason.encode!(legacy) =~ "card.sub_tasks"
      assert Jason.encode!(legacy) =~ "{sub_task_id}"

      assert conn |> push_doc("legacy-code", legacy) |> json_response(201)

      pulled = pull(conn, "legacy-code")
      refute Jason.encode!(pulled) =~ "sub_task"

      implement = Enum.find(pulled["nodes"], &(&1["key"] == "implement"))
      assert implement["foreach"] == "card.tasks"
      assert "tasks" in implement["reads"]
      assert implement["run"] =~ "{task_id}"
    end

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
        "trigger" => %{"stage" => "Deploy"},
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
      new_doc = Map.merge(doc, %{"key" => "brand-new", "version" => 42, "trigger" => %{"stage" => "Deploy"}})
      body = push_doc(conn, "brand-new", new_doc)
      assert json_response(body, 201)["data"]["version"] == 1
    end

    test "a key in the body disagreeing with the path is a 422 key_mismatch", %{conn: conn} do
      doc = pull(conn, "spec")
      body = conn |> push_doc("plan", doc) |> json_response(422)
      assert body["error"]["code"] == "key_mismatch"
    end

    test "an unresolvable trigger stage is a 422 naming it, and writes nothing", %{conn: conn, board: board} do
      doc = pull(conn, "plan")
      plan_stage_id = Flows.get_flow!(board, "plan").stage_id
      broken = put_in(doc, ["trigger", "stage"], "Nonexistent Stage")

      body = conn |> push_doc("plan", broken) |> json_response(422)

      assert body["error"]["code"] == "unknown_stages"
      assert body["error"]["message"] =~ "Nonexistent Stage"
      assert Flows.get_flow!(board, "plan").stage_id == plan_stage_id
      assert pull(conn, "plan")["trigger"] == %{"stage" => "Plan"}
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

    # RLY-241: `Schemas.Flow` casts nodes/edges as embeds, so `traverse_errors/2` hands the
    # renderer a LIST OF MAPS for those keys, not a list of strings. The shared renderer used to
    # `Enum.join` that and raise, turning every node-level graph error into a 500.
    test "a node-level graph error is a 422 invalid carrying the node's message", %{conn: conn, board: board} do
      doc = pull(conn, "spec")
      zeroed = update_in(doc, ["nodes"], fn [node | rest] -> [Map.put(node, "max_retries", 0) | rest] end)

      body = conn |> push_doc("spec", zeroed) |> json_response(422)

      assert body["error"]["code"] == "invalid"
      assert body["error"]["message"] =~ "must be greater than 0"
      assert Flows.get_flow!(board, "spec").version == 1
    end

    test "an edge-level graph error is a 422 invalid carrying the edge's message", %{conn: conn} do
      doc = pull(conn, "spec")
      looped = update_in(doc, ["edges"], fn [edge | rest] -> [Map.put(edge, "max_loops", 0) | rest] end)

      body = conn |> push_doc("spec", looped) |> json_response(422)

      assert body["error"]["code"] == "invalid"
      assert body["error"]["message"] =~ "must be greater than 0"
    end

    # RE429: a stage holds at most one flow, so moving `plan` onto Spec (where `spec` sits)
    # fails the write — and the arm in the same push rolls back with it.
    test "moving a flow onto a stage that already holds one is a 422, and rolls the write back",
         %{conn: conn, board: board} do
      plan = pull(conn, "plan")

      colliding =
        plan
        |> put_in(["trigger", "stage"], "Spec")
        |> Map.put("enabled", true)

      assert conn |> push_doc("plan", colliding) |> json_response(422)

      # The whole push rolled back: plan is still disabled AND still on its own stage.
      refute Flows.get_flow!(board, "plan").enabled
      assert pull(conn, "plan")["trigger"] == %{"stage" => "Plan"}
    end

    test "401s without a bearer token", %{conn: conn} do
      assert conn
             |> delete_req_header("authorization")
             |> put(~p"/api/flows/spec", %{})
             |> json_response(401)
    end
  end

  # RE429: a flow document carries ONE stage; where it picks cards up and drops them off is
  # worked out from board order and shipped beside it as a read-only `derived` block.
  describe "the one-stage trigger and the derived block (RE429)" do
    setup %{board: board} do
      stages = Map.new(Boards.list_stages(board), &{&1.name, &1})
      {:ok, _code_done} = Boards.enable_lane(stages["Code"], :done)
      {:ok, stages: stages}
    end

    defp audit_doc(stage) do
      %{
        "key" => "audit",
        "isolation" => "shared_clean",
        "trigger" => %{"stage" => stage},
        "nodes" => [%{"key" => "look", "type" => "agent", "run" => "/audit {ref}"}],
        "edges" => [
          %{"from" => "start", "to" => "look"},
          %{"from" => "look", "to" => "done", "on" => "succeeded"}
        ]
      }
    end

    test "1. GET /api/flows/:key carries the stage and the derived pickup and drop-off", %{conn: conn} do
      doc = pull(conn, "code")

      assert doc["trigger"] == %{"stage" => "Code"}
      assert doc["derived"] == %{"pulls_from" => "Plan:Done", "lands_on" => "Code:Done"}
    end

    test "2. GET /api/flows gives every flow a stage and a derived block; the last main stage lands nowhere",
         %{conn: conn, stages: stages} do
      {:ok, _} = Boards.delete_stage(stages["Done"])
      assert conn |> push_doc("audit", audit_doc("Deploy")) |> json_response(201)

      data = conn |> get(~p"/api/flows") |> json_response(200) |> Map.fetch!("data")

      for doc <- data do
        assert is_binary(doc["trigger"]["stage"])
        assert doc["derived"] |> Map.keys() |> Enum.sort() == ["lands_on", "pulls_from"]
      end

      audit = Enum.find(data, &(&1["key"] == "audit"))
      assert audit["derived"] == %{"pulls_from" => "Review", "lands_on" => nil}
    end

    test "3. pushing a new key onto a stage that holds another flow is a 422 stage_occupied, writing nothing",
         %{conn: conn} do
      body = conn |> push_doc("qa", "Code" |> audit_doc() |> Map.put("key", "qa")) |> json_response(422)

      assert body["error"]["code"] == "stage_occupied"
      assert body["error"]["message"] == "stage `Code` already has flow `code` — delete it or push to that key"
      assert Map.take(body["error"], ["stage", "flow"]) == %{"stage" => "Code", "flow" => "code"}
      assert conn |> get(~p"/api/flows/qa") |> json_response(404)
    end

    test "4. a legacy three-key trigger still pushes: only works_in is read", %{conn: conn, board: board, stages: stages} do
      legacy = conn |> pull("code") |> Map.put("trigger", %{"pulls_from" => "X", "works_in" => "Code", "lands_on" => "Y"})

      body = conn |> push_doc("code", legacy) |> json_response(200) |> Map.fetch!("data")

      assert body["trigger"] == %{"stage" => "Code"}
      assert Flows.get_flow!(board, "code").stage_id == stages["Code"].id
    end

    test "5. a pulled document, derived block and all, pushes back unchanged as a no-op", %{conn: conn} do
      doc = pull(conn, "code")
      assert Map.has_key?(doc, "derived")

      body = conn |> push_doc("code", doc) |> json_response(200) |> Map.fetch!("data")

      assert body["version"] == doc["version"]
      assert body == doc
    end
  end

  # RE430: a flow on a broken board shape carries its `problem`, rendered from
  # `Relay.Flows.Shape` verbatim; `nil` when the shape is fine.
  describe "the problem field (RE430)" do
    setup %{conn: conn} do
      user = insert(:user)
      board = insert(:board, owner: user)
      _backlog = insert(:stage, board: board, name: "Backlog", type: :queue, position: 1)
      code = insert(:stage, board: board, name: "Code", type: :work, category: :in_progress, position: 2)
      deploy = insert(:stage, board: board, name: "Deploy", type: :work, category: :in_progress, position: 3)
      _done = insert(:stage, board: board, name: "Done", type: :done, category: :complete, position: 4)
      insert(:flow, board: board, key: "code", enabled: true, stage_id: code.id)

      insert(:flow,
        board: board,
        key: "deploy",
        enabled: true,
        stage_id: deploy.id,
        edges: [%Schemas.Flow.Edge{from: "start", to: "done"}]
      )

      {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, user)
      conn = conn |> recycle() |> put_req_header("authorization", "Bearer " <> token)
      {:ok, conn: conn, board: board, code: code}
    end

    test "1. GET /api/flows/:key renders the flow's problem verbatim from Shape", %{conn: conn, board: board} do
      problem = pull(conn, "deploy")["problem"]

      assert problem["kind"] == "upstream_working"
      assert problem["what"] == "Flow **deploy** pulls from Code, which is flow **code**'s working stage."

      assert Enum.map(problem["fixes"], & &1["label"]) == [
               "Turn on Code · Done",
               "Insert a queue stage between Code and Deploy"
             ]

      for fix <- problem["fixes"], do: assert(fix |> Map.keys() |> Enum.sort() == ["action", "label"])
      assert problem == Relay.Flows.Shape.wire(hd(Flows.shape_problems(board)))
    end

    test "2. GET /api/flows carries problem on every document; fixing the board clears it",
         %{conn: conn, code: code} do
      data = conn |> get(~p"/api/flows") |> json_response(200) |> Map.fetch!("data")
      by_key = Map.new(data, &{&1["key"], &1})

      assert Map.has_key?(by_key["code"], "problem")
      assert by_key["code"]["problem"] == nil
      assert by_key["deploy"]["problem"]["kind"] == "upstream_working"

      {:ok, _code_done} = Boards.enable_lane(code, :done)

      assert pull(conn, "deploy")["problem"] == nil
    end

    test "3. a pulled document carrying problem pushes back unchanged", %{conn: conn} do
      doc = pull(conn, "deploy")
      assert Map.has_key?(doc, "derived")
      assert doc["problem"]

      assert conn |> push_doc("deploy", doc) |> json_response(200)
    end
  end

  describe "after a stage rename (RE385)" do
    test "pulled flows name the renamed stage", %{conn: conn, board: board} do
      spec = Enum.find(Boards.list_stages(board), &(&1.name == "Spec"))
      {:ok, _} = Boards.update_stage(spec, %{name: "Specify"})

      docs = for key <- ["code", "plan", "spec"], into: %{}, do: {key, pull(conn, key)}

      assert docs["spec"]["trigger"] == %{"stage" => "Specify"}

      for {_key, doc} <- docs do
        refute Jason.encode!(doc) =~ ~s("stage":"Spec")
      end
    end
  end
end
