defmodule RelayWeb.Api.SetupControllerTest do
  @moduledoc """
  RE443: the install handshake's two board-key endpoints. `POST /api/setup/preflight` ticks
  step 3 on the key's first authed call and records step 4's preflight result;
  `POST /api/setup/installed` finishes step 4 once the install script has written its files.
  """
  use RelayWeb.ConnCase, async: true

  alias Relay.Agents
  alias Relay.ApiKeys
  alias Relay.Boards
  alias Relay.Events
  alias Relay.Setup

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  # A bare-minimum board with step 2 done (Claude Code), and the step-3 token.
  defp setup_board(_) do
    user = insert(:user)
    board = create!(user)
    {:ok, %{token: token}} = Setup.choose_llm(board, user, "claude-code")
    %{user: user, board: board, token: token}
  end

  defp create!(user) do
    {:ok, board} =
      Boards.create_board(user, %{name: "Streaks", slug: unique_slug("streaks"), template: "bare-minimum"})

    board
  end

  defp step(board, id), do: board |> Setup.checklist() |> Map.fetch!(:steps) |> Enum.find(&(&1.id == id))

  defp checks(overrides \\ %{}) do
    for %{id: id} <- Setup.preflight_checks() do
      Map.merge(%{"id" => id, "ok" => true, "detail" => "#{id} detail"}, Map.get(overrides, id, %{}))
    end
  end

  defp preflight_body(board, attrs \\ %{}) do
    Map.merge(
      %{
        "slug" => board.slug,
        "machine" => "jl-mbp",
        "repo_dir" => "~/src/streaks",
        "remote" => "git@github.com:jl/streaks.git",
        "branch" => "main",
        "checks" => checks(),
        "clis" => %{"claude" => "/usr/bin/claude", "codex" => nil, "gemini" => nil}
      },
      attrs
    )
  end

  defp installed_body(board, attrs \\ %{}) do
    Map.merge(
      %{
        "slug" => board.slug,
        "machine" => "jl-mbp",
        "repo_dir" => "~/src/streaks",
        "branch" => "main",
        "files" => ["relay", ".claude/skills/relay-onboard/SKILL.md", "relay.md"]
      },
      attrs
    )
  end

  defp preflight(conn, token, body), do: conn |> auth(token) |> post(~p"/api/setup/preflight", body)
  defp installed(conn, token, body), do: conn |> auth(token) |> post(~p"/api/setup/installed", body)

  describe "POST /api/setup/preflight" do
    setup :setup_board

    # Scenario 3
    test "all checks ok: answers ok, ticks step 3 and leaves step 4 waiting",
         %{conn: conn, board: board, token: token} do
      four = String.slice(token, -4, 4)

      body = conn |> preflight(token, preflight_body(board)) |> json_response(200)

      assert body["ok"] == true
      assert body["board"] == "Streaks"
      assert body["headline"] == nil
      assert body["fix"] == nil
      assert body["fix_command"] == nil

      assert body["llm"] == %{
               "harness" => "claude-code",
               "label" => "Claude Code",
               "cli" => "claude",
               "skill_path" => ".claude/skills/relay-onboard/SKILL.md",
               "pointer_file" => "CLAUDE.md"
             }

      ids = Enum.map(body["checks"], & &1["id"])
      assert ids == Enum.map(Setup.preflight_checks(), & &1.id) ++ ["cli", "key"]

      assert [cli, key] = Enum.take(body["checks"], -2)
      assert %{"label" => "claude on PATH", "ok" => true, "detail" => "/usr/bin/claude", "fix" => nil} = cli

      assert %{"label" => "RELAY_API_KEY", "ok" => true} = key
      assert key["detail"] == "accepted by the board (…#{four})"

      three = step(board, "3")
      assert three.status == :done
      assert three.evidence =~ ~r/^first authed call \d\d:\d\d · key …\w{4} · jl-mbp$/
      assert three.evidence =~ "key …#{four} ·"
      assert step(board, "4").status == :waiting
      assert step(board, "4").evidence =~ ~r/^preflight passed \d\d:\d\d · jl-mbp$/
      assert [_ | _] = step(board, "4").data["checks"]
    end

    # Scenario 4
    test "the LLM's CLI missing fails step 4 with the install fix; a re-run with it present clears it",
         %{conn: conn, board: board, token: token} do
      no_cli = preflight_body(board, %{"clis" => %{"claude" => nil, "codex" => nil}})
      body = conn |> preflight(token, no_cli) |> json_response(200)

      assert body["ok"] == false
      assert body["headline"] == "Preflight stopped: Claude Code isn't on your PATH"
      assert body["fix"] == "Install it, open a new terminal, and run the same command again. Nothing was written."
      assert body["fix_command"] == "npm install -g @anthropic-ai/claude-code"
      assert %{"id" => "cli", "ok" => false, "fix" => fix} = Enum.find(body["checks"], &(&1["id"] == "cli"))
      assert fix == body["fix"]

      assert step(board, "3").status == :done
      four = step(board, "4")
      assert four.status == :failed
      assert four.error == "Preflight stopped: Claude Code isn't on your PATH"
      assert four.evidence =~ ~r/^preflight failed \d\d:\d\d · .+ · jl-mbp$/
      assert %{"ok" => false} = Enum.find(four.data["checks"], &(&1["id"] == "cli"))
      assert four.data["headline"] == body["headline"]
      assert four.data["fix"] == body["fix"]
      assert four.data["fix_command"] == body["fix_command"]

      assert conn |> preflight(token, preflight_body(board)) |> json_response(200) |> Map.fetch!("ok")

      four = step(board, "4")
      assert four.status == :waiting
      assert four.error == nil
    end

    # Scenario 5
    test "a failed local check fails step 4 and its fix names the remedy",
         %{conn: conn, board: board, token: token} do
      no_remote = preflight_body(board, %{"checks" => checks(%{"remote" => %{"ok" => false, "detail" => "no origin"}})})
      body = conn |> preflight(token, no_remote) |> json_response(200)

      assert body["ok"] == false
      assert %{"ok" => false, "fix" => fix} = Enum.find(body["checks"], &(&1["id"] == "remote"))
      assert fix =~ "git remote add origin <url>"
      assert body["headline"] =~ "Preflight stopped"
      assert step(board, "4").status == :failed
      assert step(board, "4").evidence =~ ~r/^preflight failed \d\d:\d\d · no origin · jl-mbp$/
    end

    test "every local check has its own non-empty fix text", %{conn: conn, board: board, token: token} do
      for %{id: id, label: label} <- Setup.preflight_checks() do
        failing = preflight_body(board, %{"checks" => checks(%{id => %{"ok" => false}})})
        body = conn |> preflight(token, failing) |> json_response(200)

        assert %{"ok" => false, "label" => ^label, "fix" => fix} = Enum.find(body["checks"], &(&1["id"] == id))
        assert is_binary(fix) and String.trim(fix) != ""
        assert body["fix"] == fix
      end
    end

    test "the preflight check catalog is the four local checks, in print order" do
      assert Setup.preflight_checks() == [
               %{id: "git_repo", label: "git repo"},
               %{id: "remote", label: "remote"},
               %{id: "default_branch", label: "default branch"},
               %{id: "python3", label: "python3"}
             ]
    end

    # Scenario 6
    test "a key from another board is refused with wrong_board and changes nothing",
         %{conn: conn, board: board} do
      other_user = insert(:user)
      other = create!(other_user)
      {:ok, %{token: other_token}} = Setup.choose_llm(other, other_user, "codex")
      before = {Setup.checklist(board), Setup.checklist(other)}

      for request <- [
            &preflight(&1, other_token, preflight_body(board)),
            &installed(&1, other_token, installed_body(board))
          ] do
        assert %{"error" => %{"code" => "wrong_board", "message" => "this key belongs to a different board"}} =
                 conn |> request.() |> json_response(403)
      end

      for request <- [
            &preflight(&1, other_token, preflight_body(board, %{"slug" => "no-such-board"})),
            &installed(&1, other_token, installed_body(board, %{"slug" => "no-such-board"}))
          ] do
        assert %{"error" => %{"code" => "wrong_board"}} = conn |> request.() |> json_response(403)
      end

      assert {Setup.checklist(board), Setup.checklist(other)} == before
    end

    # Scenario 9 (part): a malformed request
    test "an unknown check id is 422 invalid", %{conn: conn, board: board, token: token} do
      bad = preflight_body(board, %{"checks" => [%{"id" => "rm_rf", "ok" => true, "detail" => ""} | checks()]})

      assert %{"error" => %{"code" => "invalid"}} = conn |> preflight(token, bad) |> json_response(422)
      assert step(board, "3").status == :active
    end

    test "no bearer is 401", %{conn: conn, board: board} do
      assert %{"error" => %{"code" => "unauthorized"}} =
               conn |> post(~p"/api/setup/preflight", preflight_body(board)) |> json_response(401)
    end
  end

  # Scenario 7
  test "a board still on step 2 is refused with step_2_pending and nothing changes", %{conn: conn} do
    user = insert(:user)
    board = create!(user)
    {:ok, %{token: token}} = ApiKeys.create_key(board, user)
    before = Setup.checklist(board)

    assert %{
             "error" => %{
               "code" => "step_2_pending",
               "message" => "Pick a default LLM in the setup wizard first (step 2)."
             }
           } = conn |> preflight(token, preflight_body(board)) |> json_response(409)

    assert Setup.checklist(board) == before
  end

  # Scenario 9
  test "a board with no checklist answers from its default agent and writes no checklist", %{conn: conn} do
    board = insert(:board)
    :ok = Agents.ensure_seeded!(board)
    {:ok, %{token: token}} = ApiKeys.create_key(board, board.owner)

    body = conn |> preflight(token, preflight_body(board)) |> json_response(200)

    assert body["ok"] == true
    assert body["llm"]["harness"] == "claude-code"
    assert Setup.checklist(board) == nil

    assert %{"ok" => true} = conn |> installed(token, installed_body(board)) |> json_response(200)
    assert Setup.checklist(board) == nil
  end

  describe "POST /api/setup/installed" do
    setup :setup_board

    # Scenario 8
    test "finishes step 4 and activates step 5; a repeat changes nothing",
         %{conn: conn, board: board, token: token} do
      assert conn |> preflight(token, preflight_body(board)) |> json_response(200) |> Map.fetch!("ok")
      assert step(board, "4").status == :waiting

      board_id = board.id
      :ok = Events.subscribe(board_id)

      assert %{"ok" => true} = conn |> installed(token, installed_body(board)) |> json_response(200)

      four = step(board, "4")
      assert four.status == :done
      assert four.evidence =~ ~r/^downloaded \d\d:\d\d · ~\/src\/streaks · main$/
      assert four.data["files"] == ["relay", ".claude/skills/relay-onboard/SKILL.md", "relay.md"]
      assert step(board, "5").status == :active
      assert step(board, "5").children |> hd() |> Map.take([:id, :status]) == %{id: "5.1", status: :active}
      assert_receive {:setup_changed, ^board_id}

      before = Setup.checklist(board)

      assert %{"ok" => true} =
               conn |> installed(token, installed_body(board, %{"repo_dir" => "~/elsewhere"})) |> json_response(200)

      assert conn |> preflight(token, preflight_body(board)) |> json_response(200) |> Map.fetch!("ok")
      assert Setup.checklist(board) == before
      refute_receive {:setup_changed, _}
    end

    test "a malformed body is 422 invalid", %{conn: conn, board: board, token: token} do
      bad = installed_body(board, %{"files" => "relay"})
      assert %{"error" => %{"code" => "invalid"}} = conn |> installed(token, bad) |> json_response(422)
    end
  end

  # RE445: `GET /api/setup` and `POST /api/setup/steps/:step`.

  @walk ~w(5.1 5.2 5.3 5.4 5.5 5.6 5.7 5.8)

  # The `setup_board/1` board (step 2 done) with steps 3 and 4 finished and the checklist on
  # reportable step `id`.
  defp on_step(%{board: board} = context, id) do
    for prior <- ~w(3 4) ++ Enum.take_while(@walk, &(&1 != id)), do: {:ok, _} = Setup.advance(board, prior, :done, %{})
    context
  end

  defp on_first_sub_step(context), do: on_step(context, "5.1")

  defp status(conn, token), do: conn |> auth(token) |> get(~p"/api/setup")
  defp report(conn, token, id, body), do: conn |> auth(token) |> post(~p"/api/setup/steps/#{id}", body)

  defp wire_step(body, id),
    do: body["data"]["steps"] |> Enum.flat_map(&[&1 | &1["children"]]) |> Enum.find(&(&1["id"] == id))

  describe "GET /api/setup" do
    setup [:setup_board, :on_first_sub_step]

    # Scenario 17
    test "answers the checklist with step 5's sub-steps, the interview and no token",
         %{conn: conn, board: board, token: token} do
      response = status(conn, token)
      body = json_response(response, 200)
      data = body["data"]

      assert data["board"] == "Streaks"
      assert data["current_id"] == "5"
      assert data["current_sub_id"] == "5.1"
      assert data["current"] == "5.1"
      assert data["first_flow_stage"] == "Plan"
      assert length(data["steps"]) == 7

      five = Enum.find(data["steps"], &(&1["id"] == "5"))
      assert Enum.map(five["children"], & &1["id"]) == ~w(5.1 5.2 5.3 5.4 5.5 5.6 5.7 5.8)
      assert five["status"] == "active"
      assert wire_step(body, "5.1")["status"] == "active"
      assert wire_step(body, "5.2")["status"] == "pending"
      assert wire_step(body, "4")["status"] == "done"
      assert length(data["interview"]) == 9
      assert data["llm"]["harness"] == "claude-code"
      assert data["change_decisions"] == Setup.change_decisions()

      refute response.resp_body =~ token
      refute response.resp_body =~ "token"
      assert board.name == "Streaks"
    end
  end

  describe "POST /api/setup/steps/:step" do
    setup :setup_board

    # Scenario 18
    test "a done report on the current sub-step moves to the next", %{conn: conn, token: token} = context do
      on_step(context, "5.1")

      body = conn |> report(token, "5.1", %{"status" => "done", "evidence" => "2 flows"}) |> json_response(200)

      assert body["data"]["current"] == "5.2"
      assert wire_step(body, "5.1")["evidence"] == "2 flows"
    end

    # Scenario 19
    test "a report on a step that isn't current is 409 not_current naming the current one",
         %{conn: conn, board: board, token: token} = context do
      on_step(context, "5.3")
      before = Setup.checklist(board)

      assert %{
               "error" => %{
                 "code" => "not_current",
                 "current" => "5.3",
                 "message" => "step 5.1 isn't current; the current step is 5.3"
               }
             } = conn |> report(token, "5.1", %{"status" => "done"}) |> json_response(409)

      assert Setup.checklist(board) == before
    end

    # Scenario 20
    test "a waiting report stores 5.3's answers", %{conn: conn, token: token} = context do
      on_step(context, "5.3")

      body =
        conn
        |> report(token, "5.3", %{"status" => "waiting", "data" => %{"answers" => %{"done" => "PR merged"}}})
        |> json_response(200)

      assert body["data"]["steps"] |> Enum.at(4) |> Map.fetch!("children") |> Enum.at(2) |> get_in(["data", "answers"]) ==
               %{"done" => "PR merged"}
    end

    # Scenario 21
    test "a failed report keeps the error", %{conn: conn, token: token} = context do
      on_step(context, "5.5")

      body =
        conn
        |> report(token, "5.5", %{"status" => "failed", "error" => "422 flow implement", "data" => %{"attempts" => 3}})
        |> json_response(200)

      assert %{"status" => "failed", "error" => "422 flow implement"} = wire_step(body, "5.5")
    end

    # Scenario 22
    test "a malformed body is 422 invalid and changes nothing", %{conn: conn, board: board, token: token} = context do
      on_step(context, "5.1")
      before = Setup.checklist(board)

      for bad <- [
            %{"status" => "bogus"},
            %{"status" => "done", "data" => "x"},
            %{"status" => "done", "evidence" => 5}
          ] do
        assert %{"error" => %{"code" => "invalid"}} = conn |> report(token, "5.1", bad) |> json_response(422)
      end

      assert Setup.checklist(board) == before
    end
  end

  # Scenario 23
  test "a board with no checklist is 404 no_checklist; no bearer is 401", %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = ApiKeys.create_key(board, board.owner)
    no_checklist = %{"error" => %{"code" => "no_checklist", "message" => "no guided setup on this board"}}

    assert conn |> status(token) |> json_response(404) == no_checklist
    assert conn |> report(token, "5.1", %{"status" => "done"}) |> json_response(404) == no_checklist

    assert %{"error" => %{"code" => "unauthorized"}} = conn |> get(~p"/api/setup") |> json_response(401)

    assert %{"error" => %{"code" => "unauthorized"}} =
             conn |> post(~p"/api/setup/steps/5.1", %{"status" => "done"}) |> json_response(401)
  end
end
