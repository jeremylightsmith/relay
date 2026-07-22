defmodule Relay.Runs.TransitionsTest do
  use Relay.DataCase, async: true

  import ExUnit.CaptureLog

  alias Relay.Repo
  alias Relay.Runs.Transitions
  alias Schemas.Run

  describe "the legal graph" do
    test "edges/0 derives {from, to} pairs from the {from, to, meaning} triples" do
      assert Transitions.edges() ==
               MapSet.new(Enum.map(Transitions.transitions(), fn {f, t, _m} -> {f, t} end))
    end

    test "legal?/2 accepts every declared edge and rejects undeclared ones" do
      for {from, to, _meaning} <- Transitions.transitions() do
        assert Transitions.legal?(from, to)
      end

      assert Transitions.legal?(:running, :parked)
      assert Transitions.legal?(:failed, :running)
      refute Transitions.legal?(:done, :running)
      refute Transitions.legal?(:parked, :done)
      refute Transitions.legal?(:cancelled, :running)
    end
  end

  describe "transition/4 — legal edges" do
    test "running -> parked sets the extra columns and returns {:ok, run}" do
      run = insert(:run, status: :running, current_node: "implement")

      set = [parked_reason: :claimed, pinned_executor_name: nil]

      assert {:ok, %Run{status: :parked, parked_reason: :claimed}} =
               Transitions.transition(run, [:running], :parked, set: set)

      assert %Run{status: :parked, parked_reason: :claimed, pinned_executor_name: nil} =
               Repo.get!(Run, run.id)
    end

    test "parked -> running clears parked_reason" do
      run = insert(:run, status: :parked, parked_reason: :executor_gone)

      assert {:ok, %Run{status: :running, parked_reason: nil}} =
               Transitions.transition(run, [:parked], :running, set: [parked_reason: nil])
    end

    test "failed -> running (retry) applies a rich multi-field set" do
      run = insert(:run, status: :failed, retries: 0, failure_detail: "boom")

      assert {:ok, updated} =
               Transitions.transition(run, [:failed], :running,
                 set: [parked_reason: nil, current_node: "implement", failure_detail: nil, retries: 1]
               )

      assert %Run{status: :running, current_node: "implement", failure_detail: nil, retries: 1} =
               updated
    end

    test "cancel accepts from either active state ([:running, :parked])" do
      running = insert(:run, status: :running)
      parked = insert(:run, status: :parked, parked_reason: :needs_input)

      assert {:ok, %Run{status: :cancelled}} =
               Transitions.transition(running, Run.active_statuses(), :cancelled, set: [])

      assert {:ok, %Run{status: :cancelled}} =
               Transitions.transition(parked, Run.active_statuses(), :cancelled, set: [])
    end
  end

  describe "transition/4 — refused edges are a logged no-op" do
    test "a wrong from-state leaves the row unmutated, returns the error, and logs a warning" do
      run = insert(:run, status: :done, current_node: nil)

      log =
        capture_log(fn ->
          assert {:error, :not_in_expected_state} =
                   Transitions.transition(run, [:running], :parked, set: [parked_reason: :claimed])
        end)

      assert log =~ "#{run.id}"
      # The already-terminal run is untouched.
      assert %Run{status: :done, parked_reason: nil} = Repo.get!(Run, run.id)
    end
  end

  describe "transition/4 — an illegal edge declaration is a programming error" do
    test "raises ArgumentError when {from, to} is not in the legal graph" do
      run = insert(:run, status: :done)

      assert_raise ArgumentError, fn ->
        Transitions.transition(run, [:done], :running, set: [])
      end
    end
  end
end
