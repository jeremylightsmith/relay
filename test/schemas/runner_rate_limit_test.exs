defmodule Schemas.RunnerRateLimitTest do
  use ExUnit.Case, async: true

  alias Schemas.Runner
  alias Schemas.RunnerRateLimit

  @wire %{
    "window" => "five_hour",
    "utilization" => 0.95,
    "max" => 0.9,
    "resets_at" => 1_789_422_600,
    "reason" => "limit"
  }

  test "the vocabularies are the two windows and the two reasons" do
    assert Runner.rate_limit_windows() == ["five_hour", "seven_day"]
    assert Runner.rate_limit_reasons() == ["limit", "rejected"]
  end

  test "normalizes the heartbeat's wire object into the embed" do
    assert %RunnerRateLimit{
             window: "five_hour",
             utilization: 0.95,
             max: 0.9,
             reason: "limit",
             resets_at: ~U[2026-09-14 21:50:00Z]
           } = Runner.normalize_rate_limit(@wire)
  end

  test "a refusal with no configured limit and no reading keeps nil max and utilization" do
    wire = %{@wire | "reason" => "rejected", "max" => nil, "utilization" => nil}

    assert %RunnerRateLimit{reason: "rejected", max: nil, utilization: nil} = Runner.normalize_rate_limit(wire)
    assert Runner.rejected_rate_limit?(Runner.normalize_rate_limit(wire))
    refute Runner.rejected_rate_limit?(Runner.normalize_rate_limit(@wire))
  end

  test "integer fractions are stored as floats" do
    rate_limit = Runner.normalize_rate_limit(%{@wire | "utilization" => 1, "max" => 0})

    assert is_float(rate_limit.utilization) and rate_limit.utilization == 1.0
    assert is_float(rate_limit.max) and rate_limit.max == 0.0
  end

  test "anything it does not recognise degrades to nil instead of raising" do
    for bad <- [
          nil,
          "paused",
          [],
          %{},
          %{@wire | "window" => "one_hour"},
          %{@wire | "reason" => "tired"},
          %{@wire | "resets_at" => "soon"},
          %{@wire | "resets_at" => -5},
          %{@wire | "utilization" => "high"},
          %{@wire | "max" => -0.1}
        ] do
      assert Runner.normalize_rate_limit(bad) == nil, "expected nil for #{inspect(bad)}"
    end
  end
end
