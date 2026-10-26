defmodule Hamaca.SetupConnectTest do
  @moduledoc """
  RE446: per-machine setup ("connect a machine"). A board member runs the same checklist with their
  own key on their own machine: the board-wide steps (1, 2, 7) and the interview / customize
  sub-steps are skipped (`Setup.connect_skips/0`), and the machine's install, pull-only onboard and
  heartbeat are tracked on its own `board_setup_steps` rows. Plus `machines/1` and
  `project_answers/1` for Board settings → Setup.
  """
  use Hamaca.DataCase, async: true

  alias Hamaca.ApiKeys
  alias Hamaca.Boards
  alias Hamaca.Setup
  alias Schemas.ApiKey
  alias Schemas.BoardSetupStep
  alias Schemas.Runner
  alias Schemas.SetupMachine

  defp runner_step, do: Setup.step_id(:runner)
  defp claim_step, do: Setup.step_id(:first_claim)

  # Every step a report moves on a board, in catalog order (a parent walked through its children).
  defp walk do
    parents = for %{parent: parent} <- Setup.steps(), parent, into: MapSet.new(), do: parent
    for %{id: id} <- tl(Setup.steps()), id not in parents, do: id
  end

  # A board created from a template by Jeremy, with step 2 chosen (Claude Code) and its key.
  defp board_past_step_2 do
    owner = insert(:user, name: "Jeremy")
    {:ok, board} = Boards.create_board(owner, %{name: "Streaks", slug: unique_slug("streaks"), template: "bare-minimum"})
    {:ok, %{token: token}} = Setup.choose_llm(board, owner, "claude-code")
    {:ok, owner_key} = ApiKeys.authenticate_key(token)
    %{owner: owner, board: board, owner_key: owner_key}
  end

  # Finishes every reportable step of `target` (board or machine) up to `id`.
  defp advance_to!(target, id) do
    for prior <- Enum.take_while(walk(), &(&1 != id)),
        Setup.reportable_id(Setup.checklist(target)) == prior,
        do: {:ok, _} = Setup.advance(target, prior, :done, %{})

    target
  end

  defp connect!(board, user) do
    {:ok, %{machine: machine, token: token}} = Setup.connect_machine(board, user)
    {:ok, key} = ApiKeys.authenticate_key(token)
    %{machine: machine, key: key, token: token}
  end

  defp entry(checklist, id), do: checklist.steps |> Enum.flat_map(&[&1 | &1.children]) |> Enum.find(&(&1.id == id))

  defp runner(name, harnesses \\ []), do: %Runner{name: name, host: name, harnesses: harnesses}

  defp machine_rows(machine), do: Repo.all(from(s in BoardSetupStep, where: s.machine_id == ^machine.id))

  # Scenario 1
  test "connect_skips/0 is the board-wide steps and the interview/customize sub-steps, all catalog ids" do
    assert Setup.connect_skips() == ["1", "2", "5.2", "5.3", "5.4", "5.5", "5.7", "5.8", "7"]

    ids = Enum.map(Setup.steps(), & &1.id)
    assert Enum.all?(Setup.connect_skips(), &(&1 in ids))
  end

  describe "connect_machine/2" do
    # Scenario 2
    test "mints the member's key and starts the machine's checklist past the board-wide steps" do
      %{board: board} = board_past_step_2()
      sam = insert(:user, name: "Sam")
      before = Setup.checklist(board)

      assert {:ok, %{machine: m, checklist: c, token: "relay_" <> _}} = Setup.connect_machine(board, sam)

      assert m.user_id == sam.id
      assert %ApiKey{created_by_id: created_by} = Repo.get(ApiKey, m.api_key_id)
      assert created_by == sam.id

      assert c.connect? == true
      assert c.machine_id == m.id
      assert c.total == 6
      assert c.position == 2
      assert c.done_count == 2
      assert c.current_id == "3"

      assert %{status: :skipped, evidence: "already set up"} = entry(c, "1")
      assert %{status: :skipped, evidence: "board-wide · already chosen"} = entry(c, "2")
      assert %{status: :skipped, evidence: "board-wide · waiting for the first claim"} = entry(c, claim_step())

      assert Enum.map(c.steps, & &1.title) == [
               "Board: Streaks",
               "Default LLM: Claude Code",
               "Your key for this machine",
               "Install on this machine",
               "Onboard, pull only",
               "Start the runner",
               "First card"
             ]

      for id <- ~w(5.2 5.3 5.4 5.5 5.7 5.8), do: assert(entry(c, id).status == :skipped)
      for id <- ~w(5.1 5.6), do: assert(entry(c, id).status == :pending)
      assert entry(c, "3").status == :active
      assert is_integer(entry(c, "3").data["key_id"])

      assert length(machine_rows(m)) == length(Setup.steps())
      assert Setup.checklist(board) == before
    end

    # Scenario 3
    test "is refused while the board is still on step 2, and on a board with no checklist" do
      owner = insert(:user)
      {:ok, board} = Boards.create_board(owner, %{name: "S", slug: unique_slug("s"), template: "bare-minimum"})
      assert Setup.connect_machine(board, insert(:user)) == {:error, :step_2_pending}

      plain = insert(:board)
      assert Setup.connect_machine(plain, insert(:user)) == {:error, :no_checklist}
      assert Repo.all(from(m in SetupMachine, where: m.board_id in ^[board.id, plain.id])) == []
    end

    # Scenario 4
    test "step 7's evidence names the board's first claim once it happened" do
      %{board: board} = board_past_step_2()
      ref = "STR1"

      Repo.update_all(
        from(s in BoardSetupStep, where: s.board_id == ^board.id and is_nil(s.machine_id) and s.step == ^claim_step()),
        set: [status: :done, completed_at: ~U[2026-10-12 14:42:00Z], data: %{"card_ref" => ref}]
      )

      {:ok, %{checklist: c}} = Setup.connect_machine(board, insert(:user, name: "Sam"))

      assert entry(c, claim_step()).evidence == "board-wide · #{ref} claimed 12 Oct"
    end
  end

  # Scenario 5
  test "a machine walks 3, 4, then 5.1 and 5.6 only, then step 6" do
    %{board: board} = board_past_step_2()
    %{machine: machine} = connect!(board, insert(:user, name: "Sam"))

    {:ok, _} = Setup.advance(machine, "3", :done, %{})
    {:ok, c} = Setup.advance(machine, "4", :done, %{})
    assert Setup.reportable_id(c) == "5.1"

    {:ok, c} = Setup.advance(machine, "5.1", :done, %{})
    assert Setup.reportable_id(c) == "5.6"

    {:ok, c} = Setup.advance(machine, "5.6", :done, %{})
    assert entry(c, "5").status == :done
    assert entry(c, runner_step()).status == :active
  end

  describe "observe_heartbeat/2 with a machine key" do
    # Scenario 6
    test "finishes the machine's step 6, records its host and leaves the board alone" do
      %{board: board} = board_past_step_2()
      advance_to!(board, runner_step())
      %{machine: machine, key: sam_key} = connect!(board, insert(:user, name: "Sam"))
      advance_to!(machine, runner_step())
      board_before = Setup.checklist(board)

      :ok = Setup.observe_heartbeat(sam_key, runner("sam-linux"))

      c = Setup.checklist(machine)
      assert c.finished? == true
      assert c.done_count == 6
      assert c.position == 6
      assert %SetupMachine{host: "sam-linux", runner_name: "sam-linux"} = Repo.get!(SetupMachine, machine.id)
      assert Setup.checklist(board) == board_before
    end

    # Scenario 7
    test "a board-key heartbeat ticks the board's step 6, not the machine's" do
      %{board: board, owner_key: owner_key} = board_past_step_2()
      advance_to!(board, runner_step())
      %{machine: machine} = connect!(board, insert(:user, name: "Sam"))
      advance_to!(machine, "4")
      machine_before = Setup.checklist(machine)

      :ok = Setup.observe_heartbeat(owner_key, runner("jl-mbp"))

      assert entry(Setup.checklist(board), runner_step()).status == :done
      assert Setup.checklist(machine) == machine_before
    end
  end

  # Scenario 8
  test "target_for_key/1 routes a machine key to its machine and a board key to the board" do
    %{board: board, owner_key: owner_key} = board_past_step_2()
    %{machine: machine, key: sam_key} = connect!(board, insert(:user, name: "Sam"))

    assert %SetupMachine{id: id} = Setup.target_for_key(sam_key)
    assert id == machine.id
    assert %Schemas.Board{id: board_id} = Setup.target_for_key(owner_key)
    assert board_id == board.id
  end

  describe "connect_checklist/2" do
    # Scenario 9
    test "is the member's unfinished machine, else an unsaved preview" do
      %{board: board} = board_past_step_2()
      sam = insert(:user, name: "Sam")
      %{machine: machine} = connect!(board, sam)

      assert Setup.connect_checklist(board, sam).machine_id == machine.id

      member = insert(:user, name: "Ana")
      count = Repo.aggregate(BoardSetupStep, :count)
      preview = Setup.connect_checklist(board, member)

      assert preview.machine_id == nil
      assert preview.connect? == true
      assert preview.total == 6
      assert entry(preview, "3").status == :active
      for id <- ~w(4 5 5.1 5.6) ++ [runner_step()], do: assert(entry(preview, id).status == :pending)
      for id <- Setup.connect_skips(), do: assert(entry(preview, id).status == :skipped)
      assert Repo.aggregate(BoardSetupStep, :count) == count
      assert Repo.aggregate(from(m in SetupMachine, where: m.user_id == ^member.id), :count) == 0
    end

    test "is nil on a board with no checklist" do
      assert Setup.connect_checklist(insert(:board), insert(:user)) == nil
    end
  end

  # Scenario 10
  test "remint_key/2 on a machine points it at a new key and revokes the unused one" do
    %{board: board} = board_past_step_2()
    sam = insert(:user, name: "Sam")
    %{machine: machine} = connect!(board, sam)
    old_key_id = machine.api_key_id

    # `connect!/2` authenticated the token, which stamps `last_used_at`; make it never-used again.
    Repo.update_all(from(k in ApiKey, where: k.id == ^old_key_id), set: [last_used_at: nil])

    assert {:ok, %{token: "relay_" <> _ = token, checklist: c}} = Setup.remint_key(machine, sam)

    machine = Repo.get!(SetupMachine, machine.id)
    {:ok, new_key} = ApiKeys.authenticate_key(token)
    assert machine.api_key_id == new_key.id
    assert entry(c, "3").data["key_id"] == new_key.id
    assert Repo.get(ApiKey, old_key_id) == nil
  end

  # RE456 scenario 13
  test "remint_key/2 re-keys a machine whose step 3 was confirmed, and its key_hint follows" do
    %{board: board} = board_past_step_2()
    sam = insert(:user, name: "Sam")
    %{machine: machine} = connect!(board, sam)
    {:ok, _} = Setup.advance(machine, "3", :done, %{data: %{"machine" => "sam-mbp"}})

    assert {:ok, %{token: token}} = Setup.remint_key(machine, sam)

    {:ok, new_key} = ApiKeys.authenticate_key(token)
    assert entry(Setup.machine_checklist(machine), "3").status == :done
    assert Repo.reload!(machine).api_key_id == new_key.id
    assert Setup.machine_checklist(machine).key_hint.last_four == new_key.last_four
  end

  # RE455 scenario 11
  test "key_saved/1 finishes a machine's step 3, and remint_key/2 reopens it with a fresh key" do
    %{board: board} = board_past_step_2()
    sam = insert(:user, name: "Sam")
    %{machine: machine} = connect!(board, sam)
    old_key_id = machine.api_key_id

    assert {:ok, saved} = Setup.key_saved(machine)
    assert saved.current_id == "4"
    assert entry(saved, "3").status == :done
    assert entry(saved, "3").data["saved"] == true

    # `connect!/2` authenticated the token, which stamps `last_used_at`; make it never-used again.
    Repo.update_all(from(k in ApiKey, where: k.id == ^old_key_id), set: [last_used_at: nil])

    assert {:ok, %{token: token, checklist: c}} = Setup.remint_key(machine, sam)
    assert entry(c, "3").status == :active

    machine = Repo.get!(SetupMachine, machine.id)
    {:ok, new_key} = ApiKeys.authenticate_key(token)
    assert machine.api_key_id == new_key.id
    assert Repo.get(ApiKey, old_key_id) == nil
  end

  # Scenario 11
  test "machines/1 lists the board's own setup, then each machine with person, key, harnesses and progress" do
    %{board: board, owner: owner, owner_key: owner_key} = board_past_step_2()
    advance_to!(board, runner_step())
    :ok = Setup.observe_heartbeat(owner_key, runner("jl-mbp"))
    {:ok, _} = Setup.advance(board, claim_step(), :done, %{})

    insert(:runner,
      board: board,
      name: "jl-mbp",
      harnesses: [%{"key" => "claude-code", "installed" => true, "signed_in" => true}]
    )

    sam = insert(:user, name: "Sam")
    %{machine: machine, key: sam_key} = connect!(board, sam)
    advance_to!(machine, "4")

    assert Setup.machines(board) == [
             %{
               id: :board,
               machine: "jl-mbp",
               person: owner.name,
               key_last_four: owner_key.last_four,
               harnesses: [%{cli: "claude", signed_in: true}],
               finished?: true,
               progress: "7/7"
             },
             %{
               id: machine.id,
               machine: nil,
               person: "Sam",
               key_last_four: sam_key.last_four,
               harnesses: [],
               finished?: false,
               progress: "4 install"
             }
           ]
  end

  # Scenario 12
  test "a revoked machine key leaves the machine, with no key" do
    %{board: board} = board_past_step_2()
    %{machine: machine, key: sam_key} = connect!(board, insert(:user, name: "Sam"))

    {:ok, _} = ApiKeys.revoke(sam_key)

    assert %SetupMachine{api_key_id: nil} = Repo.get!(SetupMachine, machine.id)
    assert %{key_last_four: nil} = Enum.find(Setup.machines(board), &(&1.id == machine.id))
  end

  # Scenario 13
  test "project_answers/1 lists 5.3's answered questions in interview order" do
    %{board: board} = board_past_step_2()
    interview = Setup.step_id(:interview)

    Repo.update_all(
      from(s in BoardSetupStep, where: s.board_id == ^board.id and is_nil(s.machine_id) and s.step == ^interview),
      set: [data: %{"answers" => %{"deploy" => "stays human", "done" => "PR merged", "ui" => " "}}]
    )

    assert Setup.project_answers(board) == [
             %{id: "done", label: "Done means", answer: "PR merged"},
             %{id: "deploy", label: "Deploy", answer: "stays human"}
           ]

    assert Setup.project_answers(insert(:board)) == []
  end
end
