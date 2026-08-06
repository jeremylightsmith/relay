defmodule Relay.Runs.ResumeRefusalTest do
  use Relay.DataCase, async: false

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
end
