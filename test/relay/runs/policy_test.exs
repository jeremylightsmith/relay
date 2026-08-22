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
    test "agent-eligible AND status in [:ready, :queued] AND no unmet blocker" do
      for owner <- [:ai, nil], status <- [:ready, :queued] do
        assert Policy.pullable?(%{active_owner: owner, status: status, blocked_by: []})
      end
    end

    test "not pullable when human-owned, whatever the status" do
      for status <- [:ready, :queued] do
        refute Policy.pullable?(%{active_owner: :human, status: status, blocked_by: []})
      end
    end

    test "not pullable in a non-queueable status" do
      for owner <- [:ai, nil], status <- [:working, :needs_input, :failed, :in_review] do
        refute Policy.pullable?(%{active_owner: owner, status: status, blocked_by: []})
      end
    end

    # RE93 — the whole dispatch gate. Both dispatch surfaces read this one predicate.
    test "not pullable with any unmet dependency" do
      for owner <- [:ai, nil], status <- [:ready, :queued] do
        refute Policy.pullable?(%{active_owner: owner, status: status, blocked_by: [42]})
      end
    end

    # Built via a plain keyword list through Map.new/1 (not a map literal — the type checker
    # narrows a literal's shape and would flag the missing key at compile time) so this is a
    # genuine runtime FunctionClauseError, not a compile-time type warning.
    defp opted_out_card(fields), do: Map.new(fields)

    test "blocked_by is required, not defaulted — a caller cannot silently opt out of the gate" do
      opted_out = opted_out_card(active_owner: :ai, status: :ready)

      assert_raise FunctionClauseError, fn ->
        Policy.pullable?(opted_out)
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
