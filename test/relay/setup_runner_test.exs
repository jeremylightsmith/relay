defmodule Relay.SetupRunnerTest do
  @moduledoc """
  RE446: setup steps 6 and 7 are board-observed — the runner's heartbeat ticks step 6, the first
  node-job claim ticks step 7 and finishes setup — plus `close/1` / `reopen/1` and the payoff keys
  every checklist carries.
  """
  use Relay.DataCase, async: true

  alias Relay.ApiKeys
  alias Relay.Boards
  alias Relay.Events
  alias Relay.Setup
  alias Schemas.BoardSetupStep
  alias Schemas.Card
  alias Schemas.Runner

  defp runner_step, do: Setup.step_id(:runner)
  defp claim_step, do: Setup.step_id(:first_claim)

  defp create!(slug, user \\ nil) do
    user = user || insert(:user)
    {:ok, board} = Boards.create_board(user, %{name: "S", slug: unique_slug("setup"), template: slug})
    board
  end

  # A top-level step or a sub-step, by id.
  defp step(board, id),
    do:
      board |> Setup.checklist() |> Map.fetch!(:steps) |> Enum.flat_map(&[&1 | &1.children]) |> Enum.find(&(&1.id == id))

  defp rows(board), do: Repo.all(from(s in BoardSetupStep, where: s.board_id == ^board.id, order_by: s.id))

  # Every step a report moves, in catalog order: a parent with children is walked through them.
  defp walk do
    parents = for %{parent: parent} <- Setup.steps(), parent, into: MapSet.new(), do: parent
    for %{id: id} <- tl(Setup.steps()), id not in parents, do: id
  end

  # Moves the board's checklist to step `id` by finishing every reportable step before it.
  defp advance_to!(board, id) do
    for prior <- Enum.take_while(walk(), &(&1 != id)), do: {:ok, _} = Setup.advance(board, prior, :done, %{})
    board
  end

  defp key!(board) do
    user = insert(:user)
    {:ok, %{api_key: key}} = ApiKeys.create_key(board, user, "runner")
    key
  end

  defp runner(attrs \\ []) do
    struct(
      Runner,
      Keyword.merge(
        [
          name: "jl-mbp",
          host: "jl-mbp",
          harnesses: [%{"key" => "claude-code", "installed" => true, "signed_in" => true}]
        ],
        attrs
      )
    )
  end

  # A queued node job on a fresh card in a new stage of `category` on `board`.
  defp job_in!(board, category) do
    stage = insert(:stage, board: board, category: category, position: 100 + System.unique_integer([:positive]))
    card = insert(:card, stage: stage)
    run = insert(:run, card: card)
    execution = insert(:node_execution, run: run, outcome: nil, finished_at: nil)
    job = insert(:node_job, node_execution: execution, state: :queued, runner_name: nil, claimed_at: nil)
    {card, job}
  end

  defp ref(board, card), do: Card.format_ref(board.key, card.ref_number)

  defp finished_board! do
    board = "bare-minimum" |> create!() |> advance_to!(claim_step())
    {_card, job} = job_in!(board, :planning)
    :ok = Setup.observe_claim(job, runner())
    board
  end

  describe "observe_heartbeat/2 (step 6)" do
    # Scenario 1
    test "ticks step 6 with the machine and harness evidence and activates step 7" do
      board = "bare-minimum" |> create!() |> advance_to!(runner_step())

      assert :ok = Setup.observe_heartbeat(key!(board), runner())

      six = step(board, runner_step())
      assert six.status == :done
      assert six.evidence =~ ~r/^heartbeat \d\d:\d\d · jl-mbp · claude logged_in$/
      assert six.title == "Runner online"

      assert six.data == %{
               "host" => "jl-mbp",
               "runner" => "jl-mbp",
               "harnesses" => [%{"cli" => "claude", "signed_in" => true}]
             }

      assert step(board, claim_step()).status == :active
    end

    # Scenario 2
    test "a second heartbeat from another runner changes nothing and broadcasts nothing" do
      board = "bare-minimum" |> create!() |> advance_to!(runner_step())
      key = key!(board)
      :ok = Setup.observe_heartbeat(key, runner())
      before = step(board, runner_step())

      board_id = board.id
      Events.subscribe(board_id)
      assert :ok = Setup.observe_heartbeat(key, runner(name: "other", host: "other-box"))

      after_beat = step(board, runner_step())
      assert after_beat.evidence == before.evidence
      assert after_beat.completed_at == before.completed_at
      refute_receive {:setup_changed, _}
    end

    # Scenario 3
    test "a board still on step 5 is left alone" do
      board = "bare-minimum" |> create!() |> advance_to!("5.1")
      before = rows(board)

      assert :ok = Setup.observe_heartbeat(key!(board), runner())
      assert rows(board) == before
    end

    # Scenario 5
    test "a blank host falls back to the runner name and an uninstalled harness is omitted" do
      board = "bare-minimum" |> create!() |> advance_to!(runner_step())

      beat =
        runner(
          name: "box-1",
          host: "",
          harnesses: [
            %{"key" => "codex", "installed" => true, "signed_in" => false},
            %{"key" => "gemini-cli", "installed" => false, "signed_in" => nil}
          ]
        )

      :ok = Setup.observe_heartbeat(key!(board), beat)

      assert String.ends_with?(step(board, runner_step()).evidence, " · box-1 · codex logged_out")
    end

    test "a harness with unknown sign-in reads installed; none installed drops the harness part" do
      board = "bare-minimum" |> create!() |> advance_to!(runner_step())
      :ok = Setup.observe_heartbeat(key!(board), runner(harnesses: [%{"key" => "codex", "installed" => true}]))
      assert String.ends_with?(step(board, runner_step()).evidence, " · jl-mbp · codex installed")

      other = "bare-minimum" |> create!() |> advance_to!(runner_step())
      :ok = Setup.observe_heartbeat(key!(other), runner(harnesses: nil))
      assert step(other, runner_step()).evidence =~ ~r/^heartbeat \d\d:\d\d · jl-mbp$/
    end
  end

  describe "no checklist" do
    # Scenario 4
    test "both observers are no-ops on a board with no checklist" do
      user = insert(:user)
      {:ok, board} = Boards.create_board(user, %{name: "Plain", slug: unique_slug("plain")})
      {_card, job} = job_in!(board, :planning)

      assert :ok = Setup.observe_heartbeat(key!(board), runner())
      assert :ok = Setup.observe_claim(job, runner())
      assert rows(board) == []
    end
  end

  describe "observe_claim/2 (step 7)" do
    # Scenario 6
    test "the first claim finishes step 7 and the checklist, exposing the callout" do
      board = "bare-minimum" |> create!() |> advance_to!(claim_step())
      {card, job} = job_in!(board, :planning)
      ref = ref(board, card)

      assert :ok = Setup.observe_claim(job, %Runner{name: "jl-mbp", host: "jl-mbp"})

      seven = step(board, claim_step())
      assert seven.status == :done
      assert seven.evidence =~ ~r/^#{ref} claimed \d\d:\d\d by jl-mbp$/
      assert seven.title == "First card claimed"

      checklist = Setup.checklist(board)
      assert checklist.finished?

      assert checklist.callout == %{
               card_ref: ref,
               card_id: card.id,
               machine: "jl-mbp",
               llm: "Claude Code",
               verb: "planning"
             }
    end

    # Scenario 7
    test "the callout verb follows the claimed card's stage category at claim time" do
      building = "bare-minimum" |> create!() |> advance_to!(claim_step())
      {_card, job} = job_in!(building, :in_progress)
      :ok = Setup.observe_claim(job, runner())
      assert Setup.checklist(building).callout.verb == "building"

      other = "bare-minimum" |> create!() |> advance_to!(claim_step())
      {_card, job} = job_in!(other, :unstarted)
      :ok = Setup.observe_claim(job, runner())
      assert Setup.checklist(other).callout.verb == "working on"
    end

    # Scenario 8
    test "a later claim leaves step 7 naming the first card" do
      board = "bare-minimum" |> create!() |> advance_to!(claim_step())
      {card_a, job_a} = job_in!(board, :planning)
      {_card_b, job_b} = job_in!(board, :planning)

      :ok = Setup.observe_claim(job_a, runner())
      assert :ok = Setup.observe_claim(job_b, runner(name: "other"))

      data = step(board, claim_step()).data
      assert data["card_ref"] == ref(board, card_a)
      assert data["card_id"] == card_a.id
      assert data["runner"] == "jl-mbp"
    end

    test "a claim before step 7 is current is a no-op" do
      board = "bare-minimum" |> create!() |> advance_to!(runner_step())
      {_card, job} = job_in!(board, :planning)
      before = rows(board)

      assert :ok = Setup.observe_claim(job, runner())
      assert rows(board) == before
    end
  end

  describe "close/1 and reopen/1" do
    # Scenario 9
    test "close hides the callout and marks closed; reopen clears closed only" do
      board = finished_board!()
      board_id = board.id
      Events.subscribe(board_id)

      assert {:ok, %{closed?: true, callout: nil}} = Setup.close(board)
      assert_receive {:setup_changed, ^board_id}

      assert {:ok, %{closed?: false, callout: nil, finished?: true}} = Setup.reopen(board)
      assert_receive {:setup_changed, ^board_id}
    end

    # Scenario 10
    test "close refuses an unfinished checklist; both refuse a board with no checklist" do
      board = "bare-minimum" |> create!() |> advance_to!(runner_step())
      assert {:error, :not_finished} = Setup.close(board)

      user = insert(:user)
      {:ok, plain} = Boards.create_board(user, %{name: "Plain", slug: unique_slug("plain")})
      assert {:error, :no_checklist} = Setup.close(plain)
      assert {:error, :no_checklist} = Setup.reopen(plain.id)
    end
  end

  describe "checklist payoff keys" do
    # Scenario 11
    test "preview_checklist/2 derives started/finished/elapsed and the total" do
      llm = Setup.onboarding_llm("claude-code")
      started = ~U[2026-10-12 14:02:00Z]
      finished = ~U[2026-10-12 14:42:30Z]

      rows =
        Setup.steps()
        |> Map.new(&{&1.id, :done})
        |> Map.put("1", %{status: :done, completed_at: started})
        |> Map.put(claim_step(), %{status: :done, completed_at: finished})

      checklist = Setup.preview_checklist(rows, %{template: "Bare minimum", llm: llm})
      assert checklist.started_at == started
      assert checklist.finished_at == finished
      assert checklist.elapsed_minutes == 40
      assert checklist.total == 7
      assert checklist.closed? == false
      assert checklist.callout == nil

      unfinished = Setup.preview_checklist(%{"1" => %{status: :done, completed_at: started}}, %{llm: llm})
      assert unfinished.started_at == started
      assert unfinished.finished_at == nil
      assert unfinished.elapsed_minutes == nil
    end

    # Scenario 12
    test "step_id/1 names steps 6 and 7, both in the catalog" do
      assert Setup.step_id(:runner) == "6"
      assert Setup.step_id(:first_claim) == "7"
      ids = Enum.map(Setup.steps(), & &1.id)
      assert Setup.step_id(:runner) in ids
      assert Setup.step_id(:first_claim) in ids
    end
  end
end
