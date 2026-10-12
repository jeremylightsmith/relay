defmodule Schemas.RunnerHarnessesTest do
  @moduledoc """
  RE436 — the heartbeat's per-harness `usage` readings and the claim's harness set, normalized
  totally: any term in, malformed parts dropped, nothing raises.
  """
  use ExUnit.Case, async: true

  alias Schemas.Runner

  # The Task 3 runner's wire, as `test/fixtures/runner_contract.json`'s heartbeat carries it.
  @usage %{
    "source" => "output",
    "read_at" => 4_102_444_000,
    "windows" => [%{"label" => "5h", "used_pct" => 95, "resets_at" => 4_102_444_800}],
    "paused" => %{
      "label" => "5h",
      "used_pct" => 95,
      "pause_at" => 90,
      "resets_at" => 4_102_444_800,
      "reason" => "limit"
    }
  }

  defp entry(usage),
    do: %{"key" => "claude-code", "installed" => true, "version" => "2.1", "signed_in" => true, "usage" => usage}

  defp usage_of(usage) do
    [normalized] = Runner.normalize_harnesses([entry(usage)])
    normalized["usage"]
  end

  defp window(used_pct), do: %{"label" => "5h", "used_pct" => used_pct, "resets_at" => 4_102_444_800}

  describe "normalize_harnesses/1 usage" do
    # Scenario 1
    test "keeps a well-formed reading, with used_pct as floats" do
      assert [
               %{
                 "key" => "claude-code",
                 "installed" => true,
                 "version" => "2.1",
                 "signed_in" => true,
                 "usage" => usage
               }
             ] = Runner.normalize_harnesses([entry(@usage)])

      assert usage == %{
               "source" => "output",
               "read_at" => 4_102_444_000,
               "windows" => [%{"label" => "5h", "used_pct" => 95.0, "resets_at" => 4_102_444_800}],
               "paused" => %{
                 "label" => "5h",
                 "used_pct" => 95.0,
                 "pause_at" => 90,
                 "resets_at" => 4_102_444_800,
                 "reason" => "limit"
               }
             }

      assert is_float(usage["paused"]["used_pct"])
      assert [%{"used_pct" => pct}] = usage["windows"]
      assert is_float(pct)
    end

    # Scenario 2
    test "an unknown source drops the whole usage but keeps the entry" do
      assert [%{"key" => "claude-code", "installed" => true, "usage" => nil}] =
               Runner.normalize_harnesses([entry(%{@usage | "source" => "bogus"})])
    end

    test "a window with a non-numeric used_pct is dropped" do
      usage = usage_of(%{@usage | "windows" => [window("x"), window(40)]})
      assert usage["windows"] == [window(40.0)]
    end

    test "a paused value with an unknown reason becomes nil" do
      usage = usage_of(%{@usage | "paused" => %{@usage["paused"] | "reason" => "other"}})
      assert usage["paused"] == nil
      assert usage["source"] == "output"
    end

    test "a paused value with resets_at 0 becomes nil" do
      assert usage_of(%{@usage | "paused" => %{@usage["paused"] | "resets_at" => 0}})["paused"] == nil
    end

    test "a non-map usage is nil" do
      assert usage_of("junk") == nil
    end

    test "windows are capped at 20" do
      usage = usage_of(%{@usage | "windows" => Enum.map(1..25, &window/1)})
      assert length(usage["windows"]) == 20
      assert hd(usage["windows"]) == window(1.0)
    end

    test "a rejection with no window label or reading survives" do
      paused = %{
        "label" => nil,
        "used_pct" => nil,
        "pause_at" => nil,
        "resets_at" => 4_102_444_800,
        "reason" => "rejected"
      }

      assert usage_of(%{@usage | "paused" => paused})["paused"] == paused
    end

    test "an entry without usage normalizes to usage nil" do
      assert [%{"usage" => nil}] = Runner.normalize_harnesses([%{"key" => "codex", "installed" => false}])
    end
  end

  # Scenario 3
  describe "normalize_claim_harnesses/1" do
    test "keeps the binaries, in order" do
      assert Runner.normalize_claim_harnesses(["codex", 1, nil, "claude-code"]) == ["codex", "claude-code"]
    end

    test "a non-list means not narrowed" do
      assert Runner.normalize_claim_harnesses("x") == nil
      assert Runner.normalize_claim_harnesses(nil) == nil
    end

    test "is capped at 50" do
      keys = Enum.map(1..60, &"h#{&1}")
      assert Runner.normalize_claim_harnesses(keys) == Enum.take(keys, 50)
    end
  end
end
