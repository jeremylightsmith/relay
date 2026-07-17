defmodule Relay.CardsHealthTest do
  use ExUnit.Case, async: true

  alias Relay.Cards

  @now DateTime.from_naive!(~N[2026-07-15 12:00:00], "Etc/UTC")

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)
  defp entry(type, seconds_ago), do: %Schemas.Activity{type: type, inserted_at: ago(seconds_ago)}

  defp health(overrides) do
    Cards.health(
      Map.merge(
        %{newest: nil, heartbeat_at: nil, ai_active?: true, ai_stage?: true, now: @now},
        overrides
      )
    )
  end

  describe "health/1 — the artboard §03 decision table, in order" do
    # 2026-07-16 rejection: "only show the log status in the ai enabled columns". The stage
    # gate is checked before EVERYTHING — even a failure goes dark outside an AI column, which
    # also retires the v1 wart where an unsuperseded failure read :stopped forever.
    test "branch 1: a non-AI stage → :none, before everything else" do
      assert health(%{newest: entry(:action, 5), ai_stage?: false}) == :none
    end

    test "branch 1 beats the failure branch: a failure outside an AI column is :none" do
      assert health(%{newest: entry(:failure, 5), ai_stage?: false}) == :none
    end

    test "branch 1 beats a fresh heartbeat: a beating card outside an AI column is :none" do
      assert health(%{heartbeat_at: ago(10), ai_stage?: false}) == :none
    end

    test "branch 2: the newest entry is a failure → :stopped" do
      assert health(%{newest: entry(:failure, 5)}) == :stopped
    end

    # Ordering is the artboard's: failure is checked BEFORE ai_active. A failure that is
    # never superseded keeps reading stopped even after the AI is released — accepted for
    # v1, and in practice any subsequent move logs a :moved entry, which supersedes it.
    test "branch 2 beats branch 3: a failure with no active AI still reads :stopped" do
      assert health(%{newest: entry(:failure, 5), ai_active?: false}) == :stopped
    end

    test "branch 3: no active AI → :none, so no strip renders" do
      assert health(%{newest: entry(:action, 5), ai_active?: false}) == :none
    end

    test "branch 4: quiet past STALE_AFTER → :stale" do
      assert health(%{newest: entry(:action, 11 * 60)}) == :stale
    end

    test "branch 5: recent chatter → :live" do
      assert health(%{newest: entry(:action, 30)}) == :live
    end
  end

  describe "health/1 — the STALE_AFTER boundary (90s = 3× the runner's 30s heartbeat, RLY-148 Q4)" do
    test "exactly 90 seconds of quiet is still :live" do
      assert health(%{newest: entry(:action, 90)}) == :live
    end

    test "a hair over 90 seconds is :stale" do
      assert health(%{newest: %Schemas.Activity{type: :action, inserted_at: DateTime.add(@now, -90_001, :millisecond)}}) ==
               :stale
    end
  end

  describe "health/1 — the heartbeat is the second input (Q3→B)" do
    test "a fresh heartbeat keeps an otherwise-quiet card :live" do
      assert health(%{newest: entry(:action, 20 * 60), heartbeat_at: ago(10)}) == :live
    end

    test "a stale heartbeat cannot rescue a quiet card" do
      assert health(%{newest: entry(:action, 20 * 60), heartbeat_at: ago(20 * 60)}) == :stale
    end

    test "a heartbeat alone, with no entries, keeps the card :live" do
      assert health(%{heartbeat_at: ago(10)}) == :live
    end

    test "a stale heartbeat alone, with no entries, is :stale" do
      assert health(%{heartbeat_at: ago(20 * 60)}) == :stale
    end
  end

  # Unreachable in practice — an AI claim itself writes moved/owners_changed/status_changed
  # entries. Choosing :live over :stale means we never cry wolf on zero evidence.
  test "health/1 with no evidence at all is :live, never :stale" do
    assert health(%{}) == :live
  end
end
