defmodule Relay.Runs.ResumeRefusalTest do
  use Relay.DataCase, async: false

  import Ecto.Query

  alias Relay.Runs
  alias Schemas.Run

  setup do
    board = insert(:board)
    works = insert(:stage, board: board, name: "Code", category: :in_progress, type: :work, position: 2)
    %{board: board, works: works}
  end

  defp parked_run(works) do
    card = insert(:card, stage: works, status: :working)
    insert(:run, card: card, status: :parked, parked_reason: :executor_gone, current_node: nil)
  end

  defp refusal(run, reason), do: %{run_id: run.id, card_id: run.card_id, reason: reason}

  defp at(offset_s) do
    DateTime.utc_now() |> DateTime.add(offset_s, :second) |> DateTime.truncate(:second)
  end

  describe "record_resume_refusals/3" do
    test "stamps since and reason on the first refused tick", %{board: board, works: works} do
      run = parked_run(works)
      now = at(0)

      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :no_isolation)], now)

      assert %Run{resume_refused_since: ^now, resume_refused_reason: :no_isolation} = Runs.get_run!(run.id)
    end

    test "a later tick that is still refused does not move since", %{board: board, works: works} do
      run = parked_run(works)
      first = at(-600)

      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :no_isolation)], first)
      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :no_isolation)], at(0))

      assert %Run{resume_refused_since: ^first} = Runs.get_run!(run.id)
    end

    test "a reason that changes mid-refusal updates the reason and keeps since", %{board: board, works: works} do
      run = parked_run(works)
      first = at(-600)

      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :pinned_executor_absent)], first)
      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :no_free_slot)], at(0))

      assert %Run{resume_refused_since: ^first, resume_refused_reason: :no_free_slot} = Runs.get_run!(run.id)
    end

    test "a run that stops being refused has both columns cleared", %{board: board, works: works} do
      run = parked_run(works)

      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :no_free_slot)], at(-600))
      :ok = Runs.record_resume_refusals(board.id, [], at(0))

      assert %Run{resume_refused_since: nil, resume_refused_reason: nil} = Runs.get_run!(run.id)
    end

    test "clearing is board-scoped: another board's refused run is left alone",
         %{board: board, works: works} do
      other_board = insert(:board)
      other_works = insert(:stage, board: other_board, name: "Code", type: :work, position: 2)
      mine = parked_run(works)
      theirs = parked_run(other_works)

      :ok = Runs.record_resume_refusals(board.id, [refusal(mine, :no_free_slot)], at(-600))
      :ok = Runs.record_resume_refusals(other_board.id, [refusal(theirs, :no_free_slot)], at(-600))

      # A quiet tick on the OTHER board must not touch this board's stamp.
      :ok = Runs.record_resume_refusals(other_board.id, [], at(0))

      assert %Run{resume_refused_since: nil, resume_refused_reason: nil} = Runs.get_run!(theirs.id)
      assert %Run{resume_refused_reason: :no_free_slot} = Runs.get_run!(mine.id)
    end

    test "resume_run/2 clears the stamp", %{board: board, works: works} do
      start_supervised!(Relay.Runs.Supervisor)
      run = parked_run(works)
      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :no_free_slot)], at(-600))

      {:ok, _resumed} = Runs.resume_run(Runs.get_run!(run.id))

      assert %Run{resume_refused_since: nil, resume_refused_reason: nil} = Runs.get_run!(run.id)
    end
  end

  describe "abandon_unresumable_runs/1" do
    test "leaves a run refused for 29 minutes parked", %{board: board, works: works} do
      run = parked_run(works)
      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :no_isolation)], at(-29 * 60))

      :ok = Runs.abandon_unresumable_runs(at(0))

      assert %Run{status: :parked} = Runs.get_run!(run.id)
    end

    test "fails a run refused for 31 minutes, naming the cause on the run and the card",
         %{board: board, works: works} do
      run = parked_run(works)
      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :no_isolation)], at(-31 * 60))

      :ok = Runs.abandon_unresumable_runs(at(0))

      assert %Run{status: :failed, failure_detail: detail} = Runs.get_run!(run.id)
      assert detail =~ "resume_refused_reason=no_isolation"
      assert detail =~ "could not resume this run for 31m"

      card = Relay.Repo.get!(Schemas.Card, run.card_id)
      assert card.status == :failed

      # `list_timeline/1` merges Comment and Activity structs, so match on the struct —
      # a bare `entry.type` would KeyError on the comment `mark_failed/3` also posts.
      assert Enum.any?(Relay.Activity.list_timeline(card), fn
               %Schemas.Activity{type: :failure, text: text} ->
                 text =~ "resume_refused_reason=no_isolation"

               _entry ->
                 false
             end)
    end

    test "clears the pin when the reason proves it unhonourable", %{board: board, works: works} do
      for reason <- Run.pin_unhonourable_refusal_reasons() do
        run = parked_run(works)
        Relay.Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [pinned_executor_name: "exec-a"])
        :ok = Runs.record_resume_refusals(board.id, [refusal(run, reason)], at(-31 * 60))

        :ok = Runs.abandon_unresumable_runs(at(0))

        assert %Run{status: :failed, pinned_executor_name: nil} = Runs.get_run!(run.id)
      end
    end

    test "keeps the pin when the machine is alive and the worktree is still there",
         %{board: board, works: works} do
      for reason <- Run.resume_refusal_reasons() -- Run.pin_unhonourable_refusal_reasons() do
        run = parked_run(works)
        Relay.Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [pinned_executor_name: "exec-a"])
        :ok = Runs.record_resume_refusals(board.id, [refusal(run, reason)], at(-31 * 60))

        :ok = Runs.abandon_unresumable_runs(at(0))

        assert %Run{status: :failed, pinned_executor_name: "exec-a"} = Runs.get_run!(run.id)
      end
    end

    test "revokes a job the park left behind", %{board: board, works: works} do
      run = parked_run(works)
      execution = insert(:node_execution, run: run, node_key: "work", outcome: nil, finished_at: nil)
      job = insert(:node_job, node_execution: execution, state: :claimed)
      :ok = Runs.record_resume_refusals(board.id, [refusal(run, :no_free_slot)], at(-31 * 60))

      :ok = Runs.abandon_unresumable_runs(at(0))

      assert Relay.Repo.get!(Schemas.NodeJob, job.id).state == :revoked
    end

    test "the 30-minute window is the one named policy number" do
      assert Runs.unresumable_after_s() == 1800
    end
  end
end
