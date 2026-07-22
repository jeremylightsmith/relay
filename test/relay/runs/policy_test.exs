defmodule Relay.Runs.PolicyTest do
  use ExUnit.Case, async: true

  alias Relay.Runs.Policy

  describe "agent_may_hold?/1" do
    test "an AI-owned or unowned card is agent-eligible; a human-owned card is not" do
      assert Policy.agent_may_hold?(%{active_owner: :ai})
      assert Policy.agent_may_hold?(%{active_owner: nil})
      refute Policy.agent_may_hold?(%{active_owner: :human})
    end
  end

  describe "pullable?/1" do
    test "agent-eligible AND status in [:ready, :queued]" do
      for owner <- [:ai, nil], status <- [:ready, :queued] do
        assert Policy.pullable?(%{active_owner: owner, status: status})
      end
    end

    test "not pullable when human-owned, whatever the status" do
      for status <- [:ready, :queued] do
        refute Policy.pullable?(%{active_owner: :human, status: status})
      end
    end

    test "not pullable in a non-queueable status" do
      for owner <- [:ai, nil], status <- [:working, :needs_input, :failed, :in_review] do
        refute Policy.pullable?(%{active_owner: owner, status: status})
      end
    end
  end

  describe "resumable?/2" do
    # executor_gone park + agent-held + card not needs_input/failed.
    test "true only for an executor_gone park on an agent-held, non-blocked card" do
      run = %{status: :parked, parked_reason: :executor_gone}

      assert Policy.resumable?(run, %{active_owner: :ai, status: :working})
      assert Policy.resumable?(run, %{active_owner: nil, status: :ready})
    end

    test "false for a human-held card" do
      run = %{status: :parked, parked_reason: :executor_gone}
      refute Policy.resumable?(run, %{active_owner: :human, status: :working})
    end

    test "false when the card is needs_input or failed" do
      run = %{status: :parked, parked_reason: :executor_gone}
      refute Policy.resumable?(run, %{active_owner: :ai, status: :needs_input})
      refute Policy.resumable?(run, %{active_owner: :ai, status: :failed})
    end

    test "false for a non-executor_gone park (listener's territory) or a non-parked run" do
      card = %{active_owner: :ai, status: :working}
      refute Policy.resumable?(%{status: :parked, parked_reason: :needs_input}, card)
      refute Policy.resumable?(%{status: :parked, parked_reason: :claimed}, card)
      refute Policy.resumable?(%{status: :parked, parked_reason: nil}, card)
      refute Policy.resumable?(%{status: :running, parked_reason: nil}, card)
    end
  end
end
