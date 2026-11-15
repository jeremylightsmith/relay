defmodule Hamaca.Runs.CostTest do
  @moduledoc """
  RE516 — the outcome `cost` parse (never refuses, reads nil for anything that is not a finite,
  non-negative number) and the per-execution delta of a session's running total.
  """
  use ExUnit.Case, async: true

  alias Hamaca.Runs.Cost

  describe "parse/1" do
    test "1: a float reads as the equal Decimal" do
      assert Decimal.equal?(Cost.parse(0.4213), Decimal.new("0.4213"))
    end

    test "2: an integer reads as the equal Decimal" do
      assert Decimal.equal?(Cost.parse(2), Decimal.new("2"))
    end

    test "3: a numeric string reads as the equal Decimal" do
      assert Decimal.equal?(Cost.parse("0.75"), Decimal.new("0.75"))
    end

    test "4: zero, as a number or a string, is a valid cost of 0 — not nil" do
      for zero <- [0, "0"] do
        result = Cost.parse(zero)
        assert %Decimal{} = result
        assert Decimal.equal?(result, Decimal.new("0"))
      end
    end

    test "5: anything missing, negative, non-numeric, partial, NaN, infinite or non-scalar reads nil" do
      for bad <- [nil, -1, -0.01, "-1", "abc", "1.5abc", "", "NaN", "Infinity", "inf", true, false, [1], %{"a" => 1}] do
        assert Cost.parse(bad) == nil, "expected #{inspect(bad)} to parse to nil"
      end
    end
  end

  describe "execution_delta/2" do
    test "6: subtracts the session's prior spend from the reported running total" do
      assert Decimal.equal?(Cost.execution_delta(Decimal.new("0.75"), Decimal.new("0.30")), Decimal.new("0.45"))
    end

    test "7: clamps to zero, never negative, when the reported total is below the prior" do
      assert Decimal.equal?(Cost.execution_delta(Decimal.new("0.20"), Decimal.new("0.30")), Decimal.new("0"))
    end

    test "8: an unreported cost stays nil" do
      assert Cost.execution_delta(nil, Decimal.new("0.30")) == nil
    end
  end
end
