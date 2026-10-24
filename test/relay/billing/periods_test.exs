defmodule Relay.Billing.PeriodsTest do
  use ExUnit.Case, async: true

  alias Relay.Billing.Periods

  describe "renews_on/3" do
    test "clamps a day past the month's end to its last day" do
      assert Periods.renews_on(31, 2027, 2) == ~D[2027-02-28]
      assert Periods.renews_on(31, 2028, 2) == ~D[2028-02-29]
    end

    test "is that day when the month has it" do
      assert Periods.renews_on(4, 2026, 5) == ~D[2026-05-04]
    end
  end

  describe "period/2" do
    test "runs from the charge day to the day before next month's renewal day" do
      assert Periods.period(~D[2026-04-04], 4) == {~D[2026-04-04], ~D[2026-05-03]}
    end

    test "a billing day of 31 renews on a short month's last day" do
      assert Periods.period(~D[2026-01-31], 31) == {~D[2026-01-31], ~D[2026-02-27]}
      assert Periods.period(~D[2026-02-28], 31) == {~D[2026-02-28], ~D[2026-03-30]}
    end
  end

  test "next_renewal/1 is the day after paid_through" do
    assert Periods.next_renewal(~D[2026-05-03]) == ~D[2026-05-04]
  end

  describe "kept_billing_day/2" do
    test "keeps the stored day when start is that day's renewal in its month" do
      assert Periods.kept_billing_day(31, ~D[2026-02-28]) == 31
    end

    test "takes start's day when start is not the stored day's renewal" do
      assert Periods.kept_billing_day(31, ~D[2026-03-15]) == 15
    end

    test "takes start's day when no day is stored" do
      assert Periods.kept_billing_day(nil, ~D[2026-03-15]) == 15
    end
  end
end
