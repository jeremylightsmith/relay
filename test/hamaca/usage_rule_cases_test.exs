defmodule Hamaca.UsageRuleCasesTest do
  @moduledoc """
  RE436 — `Schemas.HarnessUsage.Rule` passes every shared case in `Hamaca.UsageRuleCases`, the
  same cases `bin/test_relay.py` runs the Python mirror against (via the contract fixture).
  """
  use ExUnit.Case, async: true

  alias Hamaca.UsageRuleCases
  alias Schemas.HarnessUsage.Rule

  @cases UsageRuleCases.cases()

  # Scenario 14
  test "every path reads its value" do
    for %{"event" => event, "path" => path, "segments" => segments, "value" => value} <- @cases["paths"] do
      assert Rule.parse_path(path) == {:ok, segments}, path
      assert Rule.read(event, path) === value, path
    end
  end

  test "every invalid path is refused" do
    for path <- @cases["invalid_paths"] do
      assert Rule.parse_path(path) == :error, inspect(path)
    end
  end

  test "every condition holds as expected" do
    for %{"event" => event, "condition" => condition, "holds" => holds} <- @cases["conditions"] do
      assert match?({:ok, _}, Rule.parse_condition(condition)), condition
      assert Rule.holds?(event, condition) == holds, condition
    end
  end

  test "every invalid condition is refused" do
    for condition <- @cases["invalid_conditions"] do
      assert Rule.parse_condition(condition) == :error, inspect(condition)
      refute Rule.holds?(%{}, condition), inspect(condition)
    end
  end

  test "every reading equals its expectation" do
    for %{"name" => name, "usage" => usage, "event" => event, "now" => now, "expect" => expect} <- @cases["readings"] do
      assert stringify(Rule.reading(usage, event, now)) === expect, name
    end
  end

  test "the cases cover the scenarios they pin" do
    names = Enum.map(@cases["readings"], & &1["name"])
    assert "claude-code allowed rate_limit_event (AC2)" in names
    assert "claude-code rejected line pauses until its resetsAt" in names
    assert "the real codex-cli 0.160.0 token_count line" in names
  end

  defp stringify(nil), do: nil

  defp stringify(%{windows: windows, refused_resets_at: refused}) do
    %{
      "windows" => Enum.map(windows, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end)),
      "refused_resets_at" => refused
    }
  end
end
