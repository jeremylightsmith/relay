defmodule RelayWeb.Api.StageControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Boards
  alias Relay.Repo

  @stage_keys ~w(id name display_name category type ai_enabled position wip_limit parent_id
                 description collapsed_by_default reject_to_stage_id)

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, board} = Boards.create_board(user, %{name: "B", key: "BB"})
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, user)
    authed = put_req_header(conn, "authorization", "Bearer " <> token)

    {:ok, conn: authed, bare: conn, board: board, user: user}
  end

  defp stage_named(board, name), do: board |> Boards.list_stages() |> Enum.find(&(&1.name == name))

  defp names(conn), do: conn |> get(~p"/api/stages") |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["name"])

  defp error(conn, status), do: conn |> json_response(status) |> Map.fetch!("error")

  defp enabled_flow(board, key, field, stage) do
    triggers =
      Map.put(
        %{
          pulls_from_stage_id: stage_named(board, "Backlog").id,
          works_in_stage_id: stage_named(board, "Code").id,
          lands_on_stage_id: stage_named(board, "Review").id
        },
        field,
        stage.id
      )

    insert(:flow, Map.merge(%{board: board, key: key, enabled: true}, triggers))
  end

  describe "GET /api/stages" do
    # Scenario 1
    test "lists the board's stages hierarchically with the full stage shape", %{conn: conn, board: board} do
      data = conn |> get(~p"/api/stages") |> json_response(200) |> Map.fetch!("data")

      assert Enum.map(data, & &1["name"]) ==
               [
                 "Backlog",
                 "Next up",
                 "Spec",
                 "Spec:Review",
                 "Spec:Done",
                 "Plan",
                 "Plan:Done",
                 "Code",
                 "Review",
                 "Deploy",
                 "Done"
               ]

      for stage <- data, do: assert(Enum.sort(Map.keys(stage)) == Enum.sort(@stage_keys))

      spec_review = Enum.find(data, &(&1["name"] == "Spec:Review"))
      assert spec_review["display_name"] == "Spec · Review"
      assert spec_review["parent_id"] == stage_named(board, "Spec").id
    end

    test "ai_enabled is derived from flows: true exactly for the stages a seeded flow works in (RE409)",
         %{conn: conn} do
      data = conn |> get(~p"/api/stages") |> json_response(200) |> Map.fetch!("data")

      assert data |> Enum.filter(& &1["ai_enabled"]) |> Enum.map(& &1["name"]) == ["Spec", "Plan", "Code"]
      assert Enum.find(data, &(&1["name"] == "Deploy"))["ai_enabled"] == false
      for stage <- data, do: assert(Enum.sort(Map.keys(stage)) == Enum.sort(@stage_keys))
    end

    test "a flow working in Review makes Review ai_enabled (RE409)", %{conn: conn, board: board} do
      insert_flow_working_in(stage_named(board, "Review"), key: "qa")

      data = conn |> get(~p"/api/stages") |> json_response(200) |> Map.fetch!("data")

      assert Enum.find(data, &(&1["name"] == "Review"))["ai_enabled"] == true
    end

    # Scenario 2
    test "401 without an Authorization header", %{bare: bare} do
      assert bare |> get(~p"/api/stages") |> json_response(401)
    end
  end

  describe "POST /api/stages" do
    # Scenario 3
    test "creates an anchored stage adopting the anchor's category", %{conn: conn, board: board} do
      spec = stage_named(board, "Spec")

      data =
        conn
        |> post(~p"/api/stages", %{"name" => "Triage", "after" => spec.id, "type" => "queue"})
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["name"] == "Triage"
      assert data["category"] == "planning"
      assert data["type"] == "queue"

      listed = names(conn)
      index = Enum.find_index(listed, &(&1 == "Triage"))
      assert Enum.at(listed, index - 1) == "Spec:Done"
      assert Enum.at(listed, index + 1) == "Plan"
    end

    # Scenario 4
    test "creates an unanchored stage with the category's default type", %{conn: conn} do
      data =
        conn
        |> post(~p"/api/stages", %{"name" => "QA", "category" => "in_progress", "wip_limit" => 2, "description" => "d"})
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["type"] == "work"
      assert data["wip_limit"] == 2
      assert data["description"] == "d"
    end

    # Scenario 5
    test "an invalid stage is 422 invalid", %{conn: conn} do
      err = conn |> post(~p"/api/stages", %{"name" => "", "category" => "planning"}) |> error(422)
      assert err["code"] == "invalid"
      assert err["message"] =~ "name"

      err = conn |> post(~p"/api/stages", %{"name" => "X", "category" => "planning", "type" => "bogus"}) |> error(422)
      assert err["code"] == "invalid"
    end

    # Scenario 6
    test "a substage, unknown or foreign anchor is 422 invalid_anchor", %{conn: conn, board: board} do
      other = insert(:stage, board: insert(:board))

      for anchor <- [stage_named(board, "Spec:Review").id, 999_999, other.id] do
        err = conn |> post(~p"/api/stages", %{"name" => "X", "after" => anchor}) |> error(422)
        assert err["code"] == "invalid_anchor"
        assert err["message"] == Boards.stage_refusal_message(:invalid_anchor)
      end
    end

    # Scenario 7
    test "both anchors is 422 invalid_request", %{conn: conn, board: board} do
      err =
        conn
        |> post(~p"/api/stages", %{
          "name" => "X",
          "before" => stage_named(board, "Backlog").id,
          "after" => stage_named(board, "Spec").id
        })
        |> error(422)

      assert err == %{"code" => "invalid_request", "message" => "send before or after, not both"}
    end
  end

  describe "PATCH /api/stages/:id" do
    # Scenario 8
    test "updates the configurable fields and clears wip_limit with null", %{conn: conn, board: board} do
      code = stage_named(board, "Code")

      data =
        conn
        |> patch(~p"/api/stages/#{code.id}", %{
          "name" => "Build",
          "wip_limit" => 3,
          "description" => "x",
          "collapsed_by_default" => true
        })
        |> json_response(200)
        |> Map.fetch!("data")

      assert %{"name" => "Build", "wip_limit" => 3, "description" => "x", "collapsed_by_default" => true} = data

      data =
        conn
        |> put_req_header("content-type", "application/json")
        |> patch(~p"/api/stages/#{code.id}", Jason.encode!(%{"wip_limit" => nil}))
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["wip_limit"] == nil
    end

    # Scenario 9
    test "a type change re-snaps the resident cards", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      card = insert(:card, stage: code, status: :working)

      data = conn |> patch(~p"/api/stages/#{code.id}", %{"type" => "queue"}) |> json_response(200) |> Map.fetch!("data")

      assert data["type"] == "queue"
      assert Repo.reload!(card).status == :ready
    end

    # Scenario 10
    test "reject_to_stage_id must be a main stage and null clears it", %{conn: conn, board: board} do
      review = stage_named(board, "Review")

      err =
        conn
        |> patch(~p"/api/stages/#{review.id}", %{"reject_to_stage_id" => stage_named(board, "Spec:Done").id})
        |> error(422)

      assert err["code"] == "invalid"

      {:ok, _} = Boards.update_stage(review, %{reject_to_stage_id: stage_named(board, "Spec").id})

      data =
        conn
        |> put_req_header("content-type", "application/json")
        |> patch(~p"/api/stages/#{review.id}", Jason.encode!(%{"reject_to_stage_id" => nil}))
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["reject_to_stage_id"] == nil
    end

    # Scenario 11
    test "no recognised field is 422 invalid_request", %{conn: conn, board: board} do
      code = stage_named(board, "Code")

      message =
        "send at least one of: name, description, type, wip_limit, collapsed_by_default, reject_to_stage_id"

      for body <- [%{}, %{"position" => 1}] do
        assert conn |> patch(~p"/api/stages/#{code.id}", body) |> error(422) ==
                 %{"code" => "invalid_request", "message" => message}
      end
    end
  end

  describe "ai_enabled is derived, not writable (RE409)" do
    @ai_refusal "ai_enabled is derived from flows — point a flow's works_in at this stage instead"

    test "PATCH with ai_enabled is 422 invalid_request", %{conn: conn, board: board} do
      code = stage_named(board, "Code")

      assert conn |> patch(~p"/api/stages/#{code.id}", %{"ai_enabled" => true}) |> error(422) ==
               %{"code" => "invalid_request", "message" => @ai_refusal}
    end

    test "PATCH with ai_enabled false alongside a name is 422 and writes nothing", %{conn: conn, board: board} do
      code = stage_named(board, "Code")

      assert conn |> patch(~p"/api/stages/#{code.id}", %{"ai_enabled" => false, "name" => "Build"}) |> error(422) ==
               %{"code" => "invalid_request", "message" => @ai_refusal}

      assert Repo.reload!(code).name == "Code"
    end

    test "POST with ai_enabled is 422 and creates no stage", %{conn: conn, board: board} do
      body = %{"name" => "QA", "category" => "in_progress", "ai_enabled" => true}

      assert conn |> post(~p"/api/stages", body) |> error(422) ==
               %{"code" => "invalid_request", "message" => @ai_refusal}

      refute stage_named(board, "QA")
    end

    test "a PATCH's show render derives ai_enabled from flows", %{conn: conn, board: board} do
      code = stage_named(board, "Code")

      data = conn |> patch(~p"/api/stages/#{code.id}", %{"wip_limit" => 3}) |> json_response(200) |> Map.fetch!("data")

      assert data["ai_enabled"] == true
    end
  end

  describe "POST /api/stages/:id/place" do
    # Scenario 12
    test "moves a stage before an anchor, adopting its category", %{conn: conn, board: board} do
      deploy = stage_named(board, "Deploy")

      data =
        conn
        |> post(~p"/api/stages/#{deploy.id}/place", %{"before" => stage_named(board, "Backlog").id})
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["category"] == "unstarted"
      assert [first | _] = names(conn)
      assert first == "Deploy"
    end

    # Scenario 13
    test "refuses a bad placement", %{conn: conn, board: board} do
      deploy = stage_named(board, "Deploy")
      backlog = stage_named(board, "Backlog")
      spec = stage_named(board, "Spec")

      for body <- [%{}, %{"before" => backlog.id, "after" => spec.id}] do
        assert conn |> post(~p"/api/stages/#{deploy.id}/place", body) |> error(422) ==
                 %{"code" => "invalid_request", "message" => "send exactly one of before or after"}
      end

      assert conn |> post(~p"/api/stages/#{deploy.id}/place", %{"before" => deploy.id}) |> error(422) ==
               %{"code" => "invalid_anchor", "message" => Boards.stage_refusal_message(:invalid_anchor)}

      spec_review = stage_named(board, "Spec:Review")

      assert conn |> post(~p"/api/stages/#{spec_review.id}/place", %{"before" => backlog.id}) |> error(422) ==
               %{"code" => "not_a_main_stage", "message" => Boards.stage_refusal_message(:not_a_main_stage)}
    end
  end

  describe "PUT /api/stages/:id/substages/:lane" do
    # Scenario 14
    test "enables a lane idempotently", %{conn: conn, board: board} do
      code = stage_named(board, "Code")

      first = conn |> put(~p"/api/stages/#{code.id}/substages/review") |> json_response(200) |> Map.fetch!("data")
      second = conn |> put(~p"/api/stages/#{code.id}/substages/review") |> json_response(200) |> Map.fetch!("data")

      assert first["id"] == second["id"]
      assert first["name"] == "Code:Review"
      assert first["display_name"] == "Code · Review"
      assert first["parent_id"] == code.id
    end

    # Scenario 15
    test "refuses an unknown lane or a substage", %{conn: conn, board: board} do
      code = stage_named(board, "Code")

      assert conn |> put(~p"/api/stages/#{code.id}/substages/bogus") |> error(422) ==
               %{"code" => "invalid_request", "message" => "lane must be one of: review, done"}

      spec_review = stage_named(board, "Spec:Review")

      assert conn |> put(~p"/api/stages/#{spec_review.id}/substages/done") |> error(422) |> Map.fetch!("code") ==
               "not_a_main_stage"
    end
  end

  describe "DELETE /api/stages/:id/substages/:lane" do
    # Scenario 16
    test "disables a lane, then reports it was not enabled", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, _} = Boards.enable_lane(code, :review)

      assert conn |> delete(~p"/api/stages/#{code.id}/substages/review") |> json_response(200) ==
               %{"data" => %{"lane" => "review", "disabled" => true}}

      assert conn |> delete(~p"/api/stages/#{code.id}/substages/review") |> json_response(200) ==
               %{"data" => %{"lane" => "review", "disabled" => false}}
    end

    # Scenario 17
    test "refuses a lane holding a card, without counts", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, done} = Boards.enable_lane(code, :done)
      insert(:card, stage: done)

      assert conn |> delete(~p"/api/stages/#{code.id}/substages/done") |> error(409) ==
               %{"code" => "not_empty", "message" => "That lane still has cards — move them out first."}
    end

    # Scenario 20 (lane half)
    test "refuses a lane an enabled flow lands on", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, done} = Boards.enable_lane(code, :done)
      enabled_flow(board, "ship", :lands_on_stage_id, done)

      err = conn |> delete(~p"/api/stages/#{code.id}/substages/done") |> error(409)
      assert err["code"] == "in_use_by_flow"
      assert err["flows"] == ["ship"]
    end
  end

  describe "DELETE /api/stages/:id" do
    # Scenario 18
    test "deletes an empty stage", %{conn: conn, board: board} do
      deploy = stage_named(board, "Deploy")

      assert conn |> delete(~p"/api/stages/#{deploy.id}") |> json_response(200) |> get_in(["data", "name"]) == "Deploy"
      refute "Deploy" in names(conn)
    end

    # Scenario 19
    test "refuses a stage holding an archived card, with counts", %{conn: conn, board: board} do
      insert(:card, stage: stage_named(board, "Code"), archived_at: DateTime.utc_now(:second))

      assert conn |> delete(~p"/api/stages/#{stage_named(board, "Code").id}") |> json_response(409) == %{
               "error" => %{
                 "code" => "not_empty",
                 "message" => "That stage still holds 0 live and 1 archived card(s) — move them out first.",
                 "live" => 0,
                 "archived" => 1
               }
             }
    end

    # Scenario 20
    test "refuses a stage an enabled flow works in", %{conn: conn, board: board} do
      deploy = stage_named(board, "Deploy")
      enabled_flow(board, "ship", :works_in_stage_id, deploy)

      assert conn |> delete(~p"/api/stages/#{deploy.id}") |> error(409) == %{
               "code" => "in_use_by_flow",
               "message" => "Flow(s) ship use this stage — disable or re-point them first.",
               "flows" => ["ship"]
             }
    end

    # Scenario 21
    test "refuses the public intake stage", %{conn: conn, board: board} do
      deploy = stage_named(board, "Deploy")
      {:ok, _} = Boards.update_public_settings(board, %{public_intake_stage_id: deploy.id})

      assert conn |> delete(~p"/api/stages/#{deploy.id}") |> error(409) ==
               %{"code" => "public_intake", "message" => Boards.stage_refusal_message(:public_intake)}
    end

    # Scenario 22
    test "refuses the board's last main stage", %{bare: bare} do
      board = insert(:board)
      {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
      only = insert(:stage, board: board, name: "Only", position: 1)

      err =
        bare
        |> put_req_header("authorization", "Bearer " <> token)
        |> delete(~p"/api/stages/#{only.id}")
        |> error(409)

      assert err == %{"code" => "last_stage", "message" => "A board needs at least one stage."}
    end

    # Scenario 23
    test "refuses a substage", %{conn: conn, board: board} do
      assert conn |> delete(~p"/api/stages/#{stage_named(board, "Spec:Review").id}") |> error(422) |> Map.fetch!("code") ==
               "not_a_main_stage"
    end
  end

  # Scenario 24
  test "another board's, unknown or non-integer stage id is 404", %{conn: conn} do
    other = insert(:stage, board: insert(:board))

    for id <- [other.id, 999_999, "abc"] do
      assert conn |> patch(~p"/api/stages/#{id}", %{"name" => "N"}) |> error(404) |> Map.fetch!("code") == "not_found"
      assert conn |> delete(~p"/api/stages/#{id}") |> error(404) |> Map.fetch!("code") == "not_found"

      assert conn |> post(~p"/api/stages/#{id}/place", %{"before" => 1}) |> error(404) |> Map.fetch!("code") ==
               "not_found"

      assert conn |> put(~p"/api/stages/#{id}/substages/review") |> error(404) |> Map.fetch!("code") == "not_found"
    end
  end
end
