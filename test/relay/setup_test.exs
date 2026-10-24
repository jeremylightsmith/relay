defmodule Relay.SetupTest do
  @moduledoc "RE443: the board-owned setup checklist (`Relay.Setup`), the step-2 LLM pick and the step-3 key."
  use Relay.DataCase, async: true

  alias Relay.Agents
  alias Relay.ApiKeys
  alias Relay.Boards
  alias Relay.Boards.Templates
  alias Relay.Events
  alias Relay.Setup
  alias Schemas.BoardSetupStep

  defp create!(slug, user \\ nil) do
    user = user || insert(:user)
    {:ok, board} = Boards.create_board(user, %{name: "S", slug: unique_slug("setup"), template: slug})
    board
  end

  # A top-level step or a sub-step, by id.
  defp step(board, id),
    do:
      board |> Setup.checklist() |> Map.fetch!(:steps) |> Enum.flat_map(&[&1 | &1.children]) |> Enum.find(&(&1.id == id))

  defp top_statuses(board), do: board |> Setup.checklist() |> Map.fetch!(:steps) |> Map.new(&{&1.id, &1.status})

  defp rows(board), do: Repo.all(from(s in BoardSetupStep, where: s.board_id == ^board.id, order_by: s.id))

  defp setup_board(_) do
    user = insert(:user)
    %{user: user, board: create!("bare-minimum", user)}
  end

  # Every step a report moves, in order: step 5 is walked through its sub-steps, never directly.
  @walk ~w(2 3 4 5.1 5.2 5.3 5.4 5.5 5.6 5.7 5.8 6 7)

  # Moves the board's checklist to step `id` by finishing every reportable step before it.
  defp advance_to!(board, id) do
    for prior <- Enum.take_while(@walk, &(&1 != id)), do: {:ok, _} = Setup.advance(board, prior, :done, %{})
    board
  end

  describe "BoardSetupStep" do
    test "statuses are the closed set in order, with its two partitions" do
      assert BoardSetupStep.statuses() == [:pending, :active, :waiting, :done, :failed, :skipped]
      assert BoardSetupStep.current_statuses() == [:active, :waiting, :failed]
      assert BoardSetupStep.finished_statuses() == [:done, :skipped]
    end
  end

  describe "preview_checklist/2" do
    test "builds a checklist with no database: unlisted steps pending, done_title only for :done" do
      llm = Setup.onboarding_llm("claude-code")

      checklist =
        Setup.preview_checklist(
          %{"1" => :done, "2" => :skipped, "3" => %{status: :failed, evidence: "preflight failed"}},
          %{template: "Bare minimum", llm: llm}
        )

      [one, two, three | rest] = checklist.steps
      assert one.title == "Board created from Bare minimum"
      assert two.status == :skipped
      assert two.title != two.done_title
      assert three.evidence == "preflight failed"
      assert Enum.all?(rest, &(&1.status == :pending))
      assert checklist.current_id == "3"
      assert checklist.done_count == 2
      assert checklist.board_id == nil
      assert checklist.llm == llm
    end

    # RE456 scenario 12
    test "checklist/1 is preview_checklist/2 over the board's rows" do
      user = insert(:user)
      board = create!("bare-minimum", user)
      {:ok, _} = Setup.choose_llm(board, user, "claude-code")
      checklist = Setup.checklist(board)
      rows = Map.new(rows(board), &{&1.step, &1})

      context =
        Map.take(checklist, [
          :board_id,
          :template,
          :template_warning,
          :llm,
          :first_flow_stage,
          :first_card_stage,
          :key_hint
        ])

      assert %{token_prefix: _, last_four: _} = context.key_hint
      assert Setup.preview_checklist(rows, context) == checklist
    end

    # RE456 scenario 12
    test "carries the context's key_hint, nil without one" do
      llm = Setup.onboarding_llm("claude-code")
      hint = %{token_prefix: "k7f2q9", last_four: "3a9c"}

      assert Setup.preview_checklist(%{"1" => :done}, %{llm: llm, key_hint: hint}).key_hint == hint
      assert Setup.preview_checklist(%{"1" => :done}, %{llm: llm}).key_hint == nil
    end
  end

  describe "start/2 via create_board/2" do
    # Scenario 1
    test "a bare-minimum board starts on step 2 with step 1 done" do
      checklist = Setup.checklist(create!("bare-minimum"))

      assert Enum.map(checklist.steps, & &1.id) == ~w(1 2 3 4 5 6 7)
      [one, two | rest] = checklist.steps

      assert one.status == :done
      assert one.title == "Board created from Bare minimum"
      assert one.evidence =~ ~r/^\d+ stages · \d+ flows · \d\d:\d\d$/
      assert two.status == :active
      assert two.reached_at
      assert Enum.all?(rest, &(&1.status == :pending))

      assert checklist.template == "Bare minimum"
      assert checklist.current_id == "2"
      assert checklist.position == 2
      assert checklist.done_count == 1
      refute checklist.finished?
    end

    # Scenario 2
    test "a board created with no template, or from the factory, has no checklist" do
      {:ok, plain} = Boards.create_board(insert(:user), %{name: "Plain", slug: unique_slug("plain")})

      for board <- [plain, insert(:board)] do
        assert Setup.checklist(board) == nil
        assert Setup.current(board) == nil
      end
    end

    # Scenario 3
    test "step 5 carries sub-steps 5.1–5.8 and names the onboarding LLM" do
      five = step(create!("bare-minimum"), "5")

      assert Enum.map(five.children, & &1.id) == ~w(5.1 5.2 5.3 5.4 5.5 5.6 5.7 5.8)
      assert Enum.all?(five.children, &(&1.status == :pending))
      assert five.title == "Onboard, in Claude Code"
      assert String.starts_with?(five.why, "Open claude in your repo and run /relay-onboard.")
    end

    # RE457 scenario 9
    test "placeholders resolve against the onboarding LLM" do
      four = step(create!("bare-minimum"), "4")

      assert ".claude/skills/relay-onboard, relay-update and relay-doctor — the Relay skills" in four.what_this_does
      refute Enum.any?(four.what_this_does, &(&1 =~ "— the onboarding skill"))
      assert "relay.md, plus one line in CLAUDE.md pointing at it" in four.what_this_does
      refute Enum.any?(four.what_this_does, &(&1 =~ "%{"))
      assert String.starts_with?(four.why, "Puts the runner and the Relay skills in your repo.")
    end

    # Scenario 10 (warning half)
    test "template_warning is three-brain's warning, nil on bare-minimum" do
      warning = Templates.get("three-brain").warning
      assert is_binary(warning)

      assert Setup.checklist(create!("three-brain")).template_warning == warning
      assert Setup.checklist(create!("bare-minimum")).template_warning == nil
    end

    # RE447 scenario 15
    test "an :evidence override is step 1's evidence verbatim; without it the count stays" do
      copied = insert(:board)
      :ok = Setup.start(copied, %{name: "Relay", evidence: "copied from Relay"})
      assert step(copied, "1").evidence == "copied from Relay"
      assert Setup.checklist(copied).template == "Relay"

      counted = insert(:board)
      :ok = Setup.start(counted, %{name: "Bare minimum"})
      assert step(counted, "1").evidence =~ ~r/^\d+ stages · \d+ flows · \d\d:\d\d$/
    end

    # Scenario 18
    test "deleting the board deletes its setup rows" do
      board = create!("bare-minimum")
      assert length(rows(board)) == 15

      {:ok, _} = Repo.delete(board)
      assert rows(board) == []
    end
  end

  describe "advance/4" do
    setup :setup_board

    # Scenario 4
    test "refuses a step that is not current, an unknown status, and a board with no checklist", %{board: board} do
      before = rows(board)

      assert Setup.advance(board, "4", :done, %{}) == {:error, :not_current}
      assert Setup.advance(board, "5.1", :done, %{}) == {:error, :not_current}
      assert rows(board) == before

      assert Setup.advance(board, "2", :bogus, %{}) == {:error, :invalid_status}
      assert Setup.advance(insert(:board), "2", :done, %{}) == {:error, :no_checklist}
    end

    # Scenario 5
    test "done completes the step, activates the next, and an identical repeat changes nothing", %{board: board} do
      attrs = %{evidence: "chosen 14:03 · change in Settings", data: %{"llm" => "codex"}}

      assert {:ok, checklist} = Setup.advance(board, "2", :done, attrs)
      assert checklist.position == 3

      two = Enum.find(checklist.steps, &(&1.id == "2"))
      assert two.status == :done
      assert two.completed_at
      assert two.evidence == "chosen 14:03 · change in Settings"

      three = Enum.find(checklist.steps, &(&1.id == "3"))
      assert three.status == :active
      assert three.reached_at

      before = rows(board)
      assert {:ok, _} = Setup.advance(board, "2", :done, attrs)
      assert rows(board) == before
    end

    # Scenario 6
    test "failed keeps the error and holds the next step; waiting then done clears it", %{board: board} do
      advance_to!(board, "4")

      assert {:ok, _} =
               Setup.advance(board, "4", :failed, %{
                 error: "Preflight stopped: Codex isn't on your PATH",
                 data: %{"checks" => [%{"name" => "codex", "ok" => false}]}
               })

      assert %{status: :failed, error: "Preflight stopped: Codex isn't on your PATH"} = step(board, "4")
      assert step(board, "5").status == :pending

      assert {:ok, _} = Setup.advance(board, "4", :waiting, %{evidence: "preflight passed 14:10 · jl-mbp"})
      assert {:ok, _} = Setup.advance(board, "4", :done, %{"evidence" => "downloaded 14:11 · ~/src/x · main"})

      four = step(board, "4")
      assert four.status == :done
      assert four.error == nil
      assert four.evidence == "downloaded 14:11 · ~/src/x · main"
      assert four.data["checks"] == [%{"name" => "codex", "ok" => false}]
      assert step(board, "5").status == :active
    end

    # Scenario 7
    test "a change broadcasts {:setup_changed, board_id}; a refusal does not", %{board: board} do
      board_id = board.id
      Events.subscribe(board_id)

      assert {:ok, _} = Setup.advance(board, "2", :done, %{})
      assert_receive {:setup_changed, ^board_id}

      assert {:error, :not_current} = Setup.advance(board, "5.1", :done, %{})
      refute_receive {:setup_changed, _}
    end

    # RE445 scenario 11
    test "advancing 2, 3, 4, 5.1…5.8, 6, 7 to done finishes the checklist", %{board: board} do
      for id <- @walk, do: assert({:ok, _} = Setup.advance(board, id, :done, %{}))

      checklist = Setup.checklist(board)
      assert checklist.finished?
      assert checklist.current_id == nil
      assert checklist.current_sub_id == nil
      assert checklist.position == 7
      assert checklist.done_count == 7
      assert Setup.current(board) == nil
    end
  end

  describe "advance/4 through step 5's sub-steps (RE445)" do
    setup :setup_board

    # Scenario 1
    test "finishing step 4 activates step 5 and its first sub-step", %{board: board} do
      checklist = board |> advance_to!("5.1") |> Setup.checklist()
      five = Enum.find(checklist.steps, &(&1.id == "5"))
      [first | rest] = five.children

      assert five.status == :active
      assert first.id == "5.1"
      assert first.status == :active
      assert first.reached_at
      assert Enum.map(rest, & &1.id) == ~w(5.2 5.3 5.4 5.5 5.6 5.7 5.8)
      assert Enum.all?(rest, &(&1.status == :pending))
      assert checklist.current_id == "5"
      assert checklist.current_sub_id == "5.1"
      assert Setup.reportable_id(checklist) == "5.1"
    end

    # Scenario 2
    test "finishing a sub-step activates the next and leaves step 5 active", %{board: board} do
      advance_to!(board, "5.1")

      assert {:ok, cl} = Setup.advance(board, "5.1", :done, %{evidence: "2 flows"})
      assert %{status: :done, evidence: "2 flows"} = step(board, "5.1")
      assert step(board, "5.2").status == :active
      assert step(board, "5").status == :active
      assert cl.current_sub_id == "5.2"
      assert cl.position == 5
    end

    # Scenario 3
    test "a later sub-step, the parent and the next top-level step are all not current", %{board: board} do
      advance_to!(board, "5.1")
      before = rows(board)

      assert Setup.advance(board, "5.2", :done, %{}) == {:error, :not_current}
      assert Setup.advance(board, "5", :done, %{}) == {:error, :not_current}
      assert Setup.advance(board, "6", :done, %{}) == {:error, :not_current}
      assert rows(board) == before
    end

    test "repeating the just-finished sub-step is a no-op; an older one is not current", %{board: board} do
      advance_to!(board, "5.3")
      before = rows(board)

      assert {:ok, _} = Setup.advance(board, "5.2", :done, %{})
      assert Setup.advance(board, "5.1", :done, %{}) == {:error, :not_current}
      assert rows(board) == before
    end

    # Scenario 4
    test "waiting reports replace the answers map and hold the sub-step", %{board: board} do
      advance_to!(board, "5.3")

      assert {:ok, _} = Setup.advance(board, "5.3", :waiting, %{data: %{"answers" => %{"done" => "PR merged"}}})

      assert {:ok, _} =
               Setup.advance(board, "5.3", :waiting, %{
                 data: %{"answers" => %{"done" => "PR merged", "landing" => "PR into main"}}
               })

      three = step(board, "5.3")
      assert three.status == :waiting
      assert three.data["answers"] == %{"done" => "PR merged", "landing" => "PR into main"}
      assert step(board, "5").status == :active
      assert step(board, "5.4").status == :pending
    end

    # Scenario 5
    test "a failed sub-step stays current; done then clears the error and moves on", %{board: board} do
      advance_to!(board, "5.5")

      assert {:ok, cl} =
               Setup.advance(board, "5.5", :failed, %{
                 error: "422 flow implement",
                 evidence: "422 · attempt 3/3",
                 data: %{"attempts" => 3}
               })

      five_five = step(board, "5.5")
      assert five_five.status == :failed
      assert five_five.error == "422 flow implement"
      assert five_five.data["attempts"] == 3
      assert step(board, "5").status == :active
      assert cl.current_sub_id == "5.5"

      assert {:ok, _} = Setup.advance(board, "5.5", :done, %{})
      assert step(board, "5.5").error == nil
      assert step(board, "5.6").status == :active
    end

    # Scenario 6
    test "finishing 5.8 finishes step 5 and activates step 6, broadcasting once", %{board: board} do
      advance_to!(board, "5.8")
      board_id = board.id
      Events.subscribe(board_id)

      assert {:ok, cl} = Setup.advance(board, "5.8", :done, %{evidence: "first card in Plan"})

      five = step(board, "5")
      assert five.status == :done
      assert five.completed_at
      assert five.evidence =~ ~r/^onboarded \d\d:\d\d$/
      assert step(board, "6").status == :active
      assert cl.current_id == "6"
      assert cl.current_sub_id == nil

      assert_receive {:setup_changed, ^board_id}
      refute_receive {:setup_changed, _}
    end

    # Scenario 7
    test "repeating the report that finished step 5 changes nothing and broadcasts nothing", %{board: board} do
      advance_to!(board, "5.8")
      assert {:ok, _} = Setup.advance(board, "5.8", :done, %{evidence: "first card in Plan"})
      before = rows(board)
      Events.subscribe(board.id)

      assert {:ok, _} = Setup.advance(board, "5.8", :done, %{evidence: "first card in Plan"})
      assert rows(board) == before
      refute_receive {:setup_changed, _}
    end

    # Scenario 8
    test "skipping a sub-step activates the next", %{board: board} do
      advance_to!(board, "5.2")

      assert {:ok, _} = Setup.advance(board, "5.2", :skipped, %{})
      assert step(board, "5.2").status == :skipped
      assert step(board, "5.3").status == :active
    end

    test "a board already sitting on step 5 with 5.1 still pending reports 5.1 as current", %{board: board} do
      advance_to!(board, "5.1")

      Repo.update_all(from(s in BoardSetupStep, where: s.board_id == ^board.id and s.step == "5.1"),
        set: [status: :pending]
      )

      checklist = Setup.checklist(board)
      assert checklist.current_sub_id == "5.1"
      assert {:ok, _} = Setup.advance(board, "5.1", :done, %{})
      assert step(board, "5.2").status == :active
    end
  end

  describe "first_flow_stage" do
    # Scenario 10
    test "is a stage on a template board" do
      assert is_binary(Setup.checklist(create!("bare-minimum")).first_flow_stage)
    end

    test "is nil in a preview unless the context passes it" do
      assert Setup.preview_checklist(%{}, %{llm: Setup.onboarding_llm("claude-code")}).first_flow_stage == nil
    end
  end

  describe "first_card_stage" do
    test "is a stage on a template board" do
      assert is_binary(Setup.checklist(create!("bare-minimum")).first_card_stage)
    end

    test "is nil in a preview unless the context passes it" do
      assert Setup.preview_checklist(%{}, %{llm: Setup.onboarding_llm("claude-code")}).first_card_stage == nil
    end
  end

  describe "choose_llm/3" do
    setup :setup_board

    # Scenario 8
    test "claude-code keeps the default, finishes step 2 and mints the step-3 key", %{board: board, user: user} do
      assert {:ok, %{token: "relay_" <> _ = token, checklist: checklist}} = Setup.choose_llm(board, user, "claude-code")

      assert Agents.default_agent(board).name == "Claude Opus"

      two = Enum.find(checklist.steps, &(&1.id == "2"))
      assert two.status == :done
      assert two.data["llm"] == "claude-code"
      assert two.evidence =~ ~r/^chosen \d\d:\d\d · change in Settings$/
      assert two.title == "Default LLM: Claude Code"

      three = Enum.find(checklist.steps, &(&1.id == "3"))
      assert three.status == :active
      assert [key] = ApiKeys.list_keys(board)
      assert key.created_by_id == user.id
      assert three.data["key_id"] == key.id
      refute inspect(Setup.checklist(board)) =~ token
    end

    # Scenario 9
    test "codex creates a Codex agent on the codex harness's first model", %{board: board, user: user} do
      assert {:ok, %{checklist: checklist}} = Setup.choose_llm(board, user, "codex")

      default = Agents.default_agent(board)
      assert default.harness.key == "codex"
      [%{models: [first_model | _]}] = Enum.filter(Agents.seed_harnesses(), &(&1.key == "codex"))
      assert default.model == first_model

      assert checklist.llm.cli == "codex"
      assert Enum.find(checklist.steps, &(&1.id == "5")).title == "Onboard, in Codex"
    end

    # Scenario 10
    test "codex on three-brain reuses the existing GPT agent" do
      user = insert(:user)
      board = create!("three-brain", user)
      agents_before = length(Agents.list_agents(board))

      assert {:ok, _} = Setup.choose_llm(board, user, "codex")

      assert Agents.default_agent(board).name == "GPT"
      assert length(Agents.list_agents(board)) == agents_before
    end

    # Scenario 11
    test "a disabled, unknown or repeated pick is refused and mints no key", %{board: board, user: user} do
      assert Setup.choose_llm(board, user, "gemini-cli") == {:error, :disabled_llm}
      assert Setup.choose_llm(board, user, "nope") == {:error, :unknown_llm}
      assert ApiKeys.list_keys(board) == []
      assert step(board, "2").status == :active

      {:ok, _} = Setup.choose_llm(board, user, "claude-code")
      assert Setup.choose_llm(board, user, "codex") == {:error, :not_current}
      assert length(ApiKeys.list_keys(board)) == 1
    end
  end

  describe "switch_llm/3" do
    setup :setup_board

    # RE456 scenario 1
    test "switches the default LLM of a finished step 2 without moving progress", %{board: board, user: user} do
      {:ok, _} = Setup.choose_llm(board, user, "claude-code")
      before = Setup.checklist(board)
      two_before = step(board, "2")

      assert {:ok, checklist} = Setup.switch_llm(board, user, "codex")

      assert Agents.default_agent(board).harness.key == "codex"
      two = step(board, "2")
      assert two.status == :done
      assert two.title == "Default LLM: Codex"
      assert two.data["llm"] == "codex"
      assert two.evidence == two_before.evidence
      assert two.completed_at == two_before.completed_at
      assert checklist.current_id == "3"
      assert checklist.position == before.position
      assert checklist.done_count == before.done_count
      assert length(ApiKeys.list_keys(board)) == 1
    end

    # RE456 scenario 2
    test "broadcasts once on a change and not at all on a repeat", %{board: board, user: user} do
      {:ok, _} = Setup.choose_llm(board, user, "claude-code")
      board_id = board.id
      Events.subscribe(board_id)

      assert {:ok, _} = Setup.switch_llm(board, user, "codex")
      assert_receive {:setup_changed, ^board_id}
      refute_receive {:setup_changed, _}

      assert {:ok, _} = Setup.switch_llm(board, user, "codex")
      refute_receive {:setup_changed, _}
    end

    # RE456 scenario 3
    test "refuses while step 2 is unfinished", %{board: board, user: user} do
      harness = Agents.default_agent(board).harness.key

      assert Setup.switch_llm(board, user, "codex") == {:error, :not_finished}
      assert Agents.default_agent(board).harness.key == harness
    end

    # RE456 scenario 4
    test "refuses a disabled or unknown LLM", %{board: board, user: user} do
      {:ok, _} = Setup.choose_llm(board, user, "claude-code")

      assert Setup.switch_llm(board, user, "gemini-cli") == {:error, :disabled_llm}
      assert Setup.switch_llm(board, user, "nope") == {:error, :unknown_llm}
      assert step(board, "2").data["llm"] == "claude-code"
    end

    # RE456 scenario 5
    test "on a finished setup it stays finished and step 5 names the new LLM", %{board: board, user: user} do
      {:ok, _} = Setup.choose_llm(board, user, "claude-code")
      advance_to!(board, "7")
      {:ok, _} = Setup.advance(board, "7", :done, %{})
      statuses = top_statuses(board)

      assert {:ok, checklist} = Setup.switch_llm(board, user, "codex")
      assert checklist.finished? == true
      assert top_statuses(board) == statuses
      assert Enum.find(checklist.steps, &(&1.id == "5")).title == "Onboard, in Codex"
    end
  end

  describe "checklist key_hint" do
    setup :setup_board

    # RE456 scenario 11
    test "is step 3's key prefix and last four", %{board: board, user: user} do
      {:ok, _} = Setup.choose_llm(board, user, "claude-code")
      [k] = ApiKeys.list_keys(board)

      assert Setup.checklist(board).key_hint == %{token_prefix: k.token_prefix, last_four: k.last_four}
    end

    # RE456 scenario 11
    test "is nil before step 3 has a key", %{board: board} do
      assert Setup.checklist(board).key_hint == nil
    end

    # RE456 scenario 11
    test "is nil once step 3's key was revoked", %{board: board, user: user} do
      {:ok, _} = Setup.choose_llm(board, user, "claude-code")
      [k] = ApiKeys.list_keys(board)
      {:ok, _} = ApiKeys.revoke(k)

      assert Setup.checklist(board).key_hint == nil
    end
  end

  describe "remint_key/2" do
    setup :setup_board

    # Scenario 12
    test "revokes an unused setup key and mints a new one", %{board: board, user: user} do
      {:ok, %{token: old}} = Setup.choose_llm(board, user, "claude-code")

      assert {:ok, %{token: new, checklist: checklist}} = Setup.remint_key(board, user)
      assert new != old
      assert ApiKeys.authenticate(old) == :error
      assert {:ok, _board} = ApiKeys.authenticate(new)
      assert [new_key] = ApiKeys.list_keys(board)
      assert Enum.find(checklist.steps, &(&1.id == "3")).data["key_id"] == new_key.id
    end

    test "a key a runner already used stays in place", %{board: board, user: user} do
      {:ok, %{token: old}} = Setup.choose_llm(board, user, "claude-code")
      {:ok, _board} = ApiKeys.authenticate(old)
      assert [%{last_used_at: %DateTime{}}] = ApiKeys.list_keys(board)

      assert {:ok, %{token: new}} = Setup.remint_key(board, user)
      assert {:ok, _} = ApiKeys.authenticate(old)
      assert {:ok, _} = ApiKeys.authenticate(new)
      assert length(ApiKeys.list_keys(board)) == 2
    end

    test "refuses while step 2 is current", %{board: board, user: user} do
      assert Setup.remint_key(board, user) == {:error, :not_current}
    end

    # RE455 scenario 4
    test "reopens a saved-but-unconfirmed step 3 with a fresh key", %{board: board, user: user} do
      {:ok, %{token: old}} = Setup.choose_llm(board, user, "claude-code")
      {:ok, _} = Setup.key_saved(board)

      assert {:ok, %{token: new, checklist: checklist}} = Setup.remint_key(board, user)
      assert new != old
      assert checklist.current_id == "3"

      assert [new_key] = ApiKeys.list_keys(board)
      key = step(board, "3")
      assert key.status == :active
      assert key.evidence == nil
      assert key.completed_at == nil
      refute Map.has_key?(key.data, "saved")
      assert key.data["key_id"] == new_key.id

      install = step(board, "4")
      assert install.status == :pending
      assert install.reached_at == nil

      assert ApiKeys.authenticate(old) == :error
    end

    # RE456 scenario 6 (replaces RE455 scenario 5, which refused)
    test "re-keys a step 3 confirmed by the install script without moving progress", %{board: board, user: user} do
      {:ok, _} = Setup.choose_llm(board, user, "claude-code")
      {:ok, _} = Setup.advance(board, "3", :done, %{data: %{"machine" => "jl-mbp"}})
      before = step(board, "3")
      install_before = step(board, "4")

      assert {:ok, %{token: new, checklist: c}} = Setup.remint_key(board, user)

      three = step(board, "3")
      assert three.status == :done
      assert three.evidence == before.evidence
      assert three.completed_at == before.completed_at
      assert three.reached_at == before.reached_at
      assert step(board, "4").status == :active
      assert step(board, "4").reached_at == install_before.reached_at
      assert c.current_id == "4"

      assert {:ok, new_key} = ApiKeys.authenticate_key(new)
      assert three.data["key_id"] == new_key.id
      assert three.data["key_id"] != before.data["key_id"]
      assert {:ok, _} = ApiKeys.authenticate(new)
    end

    # RE456 scenario 7 (replaces RE455 scenario 6, which refused)
    test "re-keys a saved step 3 confirmed by a preflight, revoking the unused key", %{board: board, user: user} do
      {:ok, %{token: old}} = Setup.choose_llm(board, user, "claude-code")
      {:ok, _} = Setup.key_saved(board)
      key_id = step(board, "3").data["key_id"]

      {1, _} =
        Repo.update_all(from(s in BoardSetupStep, where: s.board_id == ^board.id and s.step == "3"),
          set: [data: %{"saved" => true, "machine" => "jl-mbp", "key_id" => key_id}]
        )

      three_before = step(board, "3")
      four_before = step(board, "4")

      assert {:ok, %{token: new}} = Setup.remint_key(board, user)

      three = step(board, "3")

      assert Map.take(three, [:status, :evidence, :completed_at, :reached_at]) ==
               Map.take(three_before, [:status, :evidence, :completed_at, :reached_at])

      assert three.data["saved"] == true
      assert three.data["machine"] == "jl-mbp"

      assert Map.take(step(board, "4"), [:status, :evidence, :reached_at]) ==
               Map.take(four_before, [:status, :evidence, :reached_at])

      assert ApiKeys.authenticate(old) == :error
      assert {:ok, _} = ApiKeys.authenticate(new)
      assert [_one] = ApiKeys.list_keys(board)
    end

    # RE456 scenario 8
    test "a confirmed step 3 whose key was used keeps the old key", %{board: board, user: user} do
      {:ok, %{token: old}} = Setup.choose_llm(board, user, "claude-code")
      {:ok, _} = Setup.advance(board, "3", :done, %{data: %{"machine" => "jl-mbp"}})
      {:ok, _} = ApiKeys.authenticate(old)

      assert {:ok, %{token: new}} = Setup.remint_key(board, user)
      assert {:ok, _} = ApiKeys.authenticate(old)
      assert {:ok, _} = ApiKeys.authenticate(new)
      assert length(ApiKeys.list_keys(board)) == 2
    end

    # RE456 scenario 9
    test "re-keys a finished setup and it stays finished", %{board: board, user: user} do
      {:ok, _} = Setup.choose_llm(board, user, "claude-code")
      advance_to!(board, "7")
      {:ok, _} = Setup.advance(board, "7", :done, %{})

      assert {:ok, %{checklist: c}} = Setup.remint_key(board, user)
      assert c.finished? == true
      assert c.position == 7
      assert c.done_count == 7
    end
  end

  describe "key_saved/1" do
    setup :setup_board

    # RE455 scenario 1
    test "finishes step 3 on the user's say-so and opens step 4", %{board: board, user: user} do
      {:ok, _} = Setup.choose_llm(board, user, "claude-code")
      Events.subscribe(board.id)

      assert {:ok, checklist} = Setup.key_saved(board)
      assert checklist.current_id == "4"

      key = step(board, "3")
      assert key.status == :done
      assert key.evidence =~ ~r/^saved \d\d:\d\d · confirmed when the install script calls in$/
      assert key.data["saved"] == true
      assert step(board, "4").status == :active

      board_id = board.id
      assert_receive {:setup_changed, ^board_id}
    end

    # RE455 scenario 2
    test "is refused while step 2 is current", %{board: board} do
      assert Setup.key_saved(board) == {:error, :not_current}
      assert step(board, "3").status == :pending
    end
  end

  describe "key_unconfirmed?/1" do
    setup :setup_board

    # RE455 scenario 3
    test "is false while step 3 is current", %{board: board, user: user} do
      {:ok, _} = Setup.choose_llm(board, user, "claude-code")
      refute Setup.key_unconfirmed?(Setup.checklist(board))
    end

    test "is true once the key is saved", %{board: board, user: user} do
      {:ok, _} = Setup.choose_llm(board, user, "claude-code")
      {:ok, _} = Setup.key_saved(board)
      assert Setup.key_unconfirmed?(Setup.checklist(board))
    end

    test "is false when step 3 finished without being saved", %{board: board} do
      advance_to!(board, "4")
      refute Setup.key_unconfirmed?(Setup.checklist(board))
    end

    test "is false once step 4 is no longer current", %{board: board, user: user} do
      {:ok, _} = Setup.choose_llm(board, user, "claude-code")
      {:ok, _} = Setup.key_saved(board)
      {:ok, _} = Setup.advance(board, "4", :done, %{})
      refute Setup.key_unconfirmed?(Setup.checklist(board))
    end
  end

  describe "catalog" do
    # Scenario 13
    test "onboarding_llms/0 reads harness and label from the seed harnesses" do
      llms = Setup.onboarding_llms()
      seeds = Map.new(Agents.seed_harnesses(), &{&1.key, &1.name})

      assert Enum.map(llms, & &1.harness) == ["claude-code", "codex", "gemini-cli"]
      assert Enum.all?(llms, &(seeds[&1.harness] == &1.label))
      assert for(%{enabled?: false, harness: h} <- llms, do: h) == ["gemini-cli"]
      assert Setup.onboarding_llm("codex").pointer_file == "AGENTS.md"
      assert Setup.onboarding_llm("nope") == nil
    end

    # RE457 scenario 4
    test "onboarding_llm/1 carries each LLM's skill_dir and derives skill_path from it" do
      claude = Setup.onboarding_llm("claude-code")
      assert claude.skill_dir == ".claude/skills"
      assert claude.skill_path == ".claude/skills/relay-onboard/SKILL.md"
      assert claude.pointer_file == "CLAUDE.md"

      codex = Setup.onboarding_llm("codex")
      assert codex.skill_dir == ".agents/skills"
      assert codex.skill_path == ".agents/skills/relay-onboard/SKILL.md"

      gemini = Setup.onboarding_llm("gemini-cli")
      assert gemini.skill_dir == nil
      assert gemini.skill_path == nil
    end

    # RE457 scenario 5
    test "pointer_line/0 is the relay.md pointer line" do
      assert Setup.pointer_line() == "Working Relay cards from this repo: see [relay.md](relay.md)."
    end

    # RE457 scenario 6
    test "llm_switch_notice/2 from Claude Code to Codex names the codex update command" do
      assert Setup.llm_switch_notice("claude-code", "codex") ==
               "Your board's default LLM is now Codex. In your repo run ./relay update --skill-dir .agents/skills --pointer-file AGENTS.md and commit the result."
    end

    # RE457 scenario 7
    test "llm_switch_notice/2 from Codex to Claude Code names the claude update command" do
      assert Setup.llm_switch_notice("codex", "claude-code") ==
               "Your board's default LLM is now Claude Code. In your repo run ./relay update --skill-dir .claude/skills --pointer-file CLAUDE.md and commit the result."
    end

    # RE457 scenario 8
    test "llm_switch_notice/2 is nil when the skill dir doesn't change or there is none" do
      assert Setup.llm_switch_notice("claude-code", "claude-code") == nil
      assert Setup.llm_switch_notice("claude-code", "gemini-cli") == nil
      assert Setup.llm_switch_notice("claude-code", "my-custom-harness") == nil
      assert Setup.llm_switch_notice(nil, "claude-code") == nil
    end

    # Scenario 14
    test "install_command/2 trims the base URL's trailing slash" do
      assert Setup.install_command("https://relay.test/", "streaks") ==
               "curl -fsSL https://relay.test/b/streaks/install | sh"
    end

    # RE443 task 4: the wizard branches on these steps without re-typing their ids.
    test "step_id/1 names the catalog id of each step the board drives" do
      assert Setup.step_id(:llm) == "2"
      assert Setup.step_id(:key) == "3"
      assert Setup.step_id(:install) == "4"
      assert Setup.step_id(:onboard) == "5"
      assert Enum.find(Setup.steps(), &(&1.id == Setup.step_id(:onboard))).actor == :ai_terminal
    end

    # RE445 task 3: the wizard's answers and changes blocks branch on 5.3 / 5.4 by role.
    test "step_id/1 names the interview and customize sub-steps" do
      assert Setup.step_id(:interview) == "5.3"
      assert Setup.step_id(:customize) == "5.4"
    end

    # RE445 scenario 9
    test "interview_questions/0 and change_decisions/0 are the 5.3 and 5.4 closed sets" do
      questions = Setup.interview_questions()

      assert Enum.map(questions, & &1.id) == ~w(done landing deploy baton ui never_touch warm_up capacity misfits)

      assert Enum.map(questions, & &1.label) ==
               [
                 "Done means",
                 "Changes land",
                 "Deploy",
                 "Baton back",
                 "UI",
                 "Never touch",
                 "Warm-up",
                 "Capacity",
                 "Misfits"
               ]

      assert Enum.all?(questions, &(is_binary(&1.question) and String.trim(&1.question) != ""))
      assert Setup.change_decisions() == ["pending", "asking", "accepted", "rejected", "edited"]
    end

    # RE447 task 3, scenario 1
    test "missing_file_resolutions/0 is 5.4's closed set of missing-file resolutions" do
      assert Setup.missing_file_resolutions() == ["stub", "inline", "drop", "path"]
    end

    # Scenario 15
    test "steps/0 is the catalog in order, every actor known, every child under step 5" do
      steps = Setup.steps()
      ids = Enum.map(steps, & &1.id)

      assert ids == ~w(1 2 3 4 5 5.1 5.2 5.3 5.4 5.5 5.6 5.7 5.8 6 7)
      assert ids == Enum.uniq(ids)
      assert Enum.all?(steps, &(&1.actor in Setup.actors()))
      assert for(%{parent: parent} <- steps, parent, uniq: true, do: parent) == ["5"]

      assert Enum.all?(steps, fn step ->
               step |> Map.keys() |> Enum.sort() ==
                 Enum.sort([
                   :id,
                   :parent,
                   :title,
                   :done_title,
                   :actor,
                   :why,
                   :what_this_does,
                   :read_only_note,
                   :connect_title,
                   :connect_why,
                   :short
                 ])
             end)
    end
  end

  describe "list_for_admin/1" do
    @now ~U[2026-01-01 12:00:00Z]

    defp set_step!(board, id, fields),
      do: Repo.update_all(from(s in BoardSetupStep, where: s.board_id == ^board.id and s.step == ^id), set: fields)

    defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

    defp admin_row(board), do: Enum.find(Setup.list_for_admin(@now), &(&1.board_id == board.id))

    # Scenario 1
    test "stuck_after/0 is two hours and admin_states/0 the three row states in chip order" do
      assert Setup.stuck_after() == 7200
      assert Setup.admin_states() == [:in_progress, :stuck, :done]
    end

    # Scenario 2
    test "one row per guided-setup board, none for a board created without a template" do
      owner = insert(:user, email: "ana@pantry.io")
      {:ok, board} = Boards.create_board(owner, %{name: "Pantry", slug: unique_slug("pantry"), template: "bare-minimum"})
      {:ok, _plain} = Boards.create_board(owner, %{name: "Plain", slug: unique_slug("plain")})

      assert [row] = Setup.list_for_admin(@now)
      assert row.board_id == board.id
      assert row.name == "Pantry"
      assert row.slug == board.slug
      assert row.owner_email == "ana@pantry.io"
      assert row.inserted_at == board.inserted_at
      assert row.template == Templates.get("bare-minimum").name
      assert row.template == Repo.get_by!(BoardSetupStep, board_id: board.id, step: "1").data["template"]
      assert row.llm == nil
      assert row.current == %{id: "2", title: "Pick your default LLM", status: :active, actor: :you_here}
    end

    # Scenario 3
    test "on_step and total count seconds from step reached and step 1 completed" do
      board = create!("bare-minimum")
      set_step!(board, "1", completed_at: ago(30 * 60))
      set_step!(board, "2", reached_at: ago(10 * 60))
      evidence = Repo.get_by!(BoardSetupStep, board_id: board.id, step: "1").evidence
      assert evidence =~ ~r/^\d+ stages · \d+ flows · \d\d:\d\d$/

      row = admin_row(board)
      assert row.on_step == 600
      assert row.total == 1800
      assert row.stuck? == false
      assert row.state == :in_progress
      assert row.last == %{kind: :evidence, text: evidence}
    end

    # Scenario 4
    test "a failed step is current and its error is the last line; the llm is step 2's label" do
      board = create!("bare-minimum")
      {:ok, _} = Setup.advance(board, "2", :done, %{evidence: "chosen 14:03", data: %{"llm" => "codex"}})
      {:ok, _} = Setup.advance(board, "3", :done, %{})

      {:ok, _} =
        Setup.advance(board, "4", :failed, %{
          error: "Preflight stopped: python3 isn't on your PATH",
          evidence: "preflight failed 14:09"
        })

      row = admin_row(board)
      assert row.llm == "Codex"
      assert row.current.id == "4"
      assert row.current.status == :failed
      assert row.last == %{kind: :error, text: "Preflight stopped: python3 isn't on your PATH"}
    end

    # Scenario 5
    test "exactly stuck_after/0 on one step is not stuck" do
      board = advance_to!(create!("bare-minimum"), "3")
      set_step!(board, "3", reached_at: ago(7200))

      row = admin_row(board)
      assert row.on_step == 7200
      assert row.stuck? == false
      assert row.state == :in_progress
    end

    # Scenario 6
    test "one second past stuck_after/0 is stuck" do
      board = advance_to!(create!("bare-minimum"), "3")
      set_step!(board, "3", reached_at: ago(7201))

      row = admin_row(board)
      assert row.stuck? == true
      assert row.state == :stuck
    end

    # Scenario 7
    test "a finished checklist is done, current on step 7, total up to step 7's completion" do
      board = advance_to!(create!("bare-minimum"), "7")
      {:ok, _} = Setup.advance(board, "7", :done, %{evidence: "STR-1 claimed by jl-mbp"})
      set_step!(board, "1", completed_at: ago(3 * 3600))
      set_step!(board, "7", completed_at: ago(2 * 3600 + 20 * 60))

      row = admin_row(board)
      assert row.state == :done
      assert row.stuck? == false
      assert row.on_step == nil
      assert row.current.id == "7"
      assert row.total == 2400
      assert row.last == %{kind: :evidence, text: "STR-1 claimed by jl-mbp"}
    end

    # Scenario 8
    test "on step 5 the current sub-step is reported, timed from step 5" do
      board = advance_to!(create!("bare-minimum"), "5.1")
      set_step!(board, "5", reached_at: ago(3600))

      Repo.update_all(from(s in BoardSetupStep, where: s.board_id == ^board.id and s.step in ~w(5.1 5.2 5.3 5.4 5.5)),
        set: [status: :done]
      )

      set_step!(board, "5.6", status: :waiting, evidence: "PR #4 open")

      row = admin_row(board)
      assert row.current == %{id: "5.6", title: "Relay files on origin/main", status: :waiting, actor: :ai_terminal}
      assert row.on_step == 3600
      assert row.last == %{kind: :evidence, text: "PR #4 open"}
    end

    # Scenario 9
    test "newest board first" do
      a = create!("bare-minimum")
      b = create!("bare-minimum")
      Repo.update_all(from(x in Schemas.Board, where: x.id == ^a.id), set: [inserted_at: ~U[2026-01-01 10:00:00Z]])
      Repo.update_all(from(x in Schemas.Board, where: x.id == ^b.id), set: [inserted_at: ~U[2026-01-01 11:00:00Z]])

      assert Enum.map(Setup.list_for_admin(@now), & &1.board_id) == [b.id, a.id]
    end

    # Scenario 10
    test "the row's checklist is the board's checklist" do
      board = create!("bare-minimum")
      {:ok, _} = Setup.advance(board, "2", :done, %{data: %{"llm" => "claude-code"}})

      row = admin_row(board)
      assert row.checklist == Setup.checklist(board)
      assert row.checklist.board_id == board.id
    end

    # Scenario 11
    test "lists every board with a constant number of queries" do
      for _ <- 1..3, do: create!("bare-minimum")
      test_pid = self()
      handler_id = {__MODULE__, :list_for_admin_queries, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:relay, :repo, :query],
          fn _event, _measurements, metadata, _config ->
            if self() == test_pid, do: send(test_pid, {:query, metadata.source})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert length(Setup.list_for_admin(@now)) == 3
      assert_received {:query, "board_setup_steps"}
      assert_received {:query, "stages"}
      refute_received {:query, _}
    end
  end
end
