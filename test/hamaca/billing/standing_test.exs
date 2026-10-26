defmodule Hamaca.Billing.StandingTest do
  use ExUnit.Case, async: true

  alias Hamaca.Billing.Standing
  alias Schemas.BillingAccount

  @today ~D[2026-10-25]
  @card "pm_card_visa"
  @no_decline %{first_charge_declined?: false, next_charge_free?: false}
  @declined %{first_charge_declined?: true, next_charge_free?: false}
  @free_code %{first_charge_declined?: false, next_charge_free?: true}

  # {label, account, facts, expected standing on @today}
  @rows [
    {"nil account", nil, @no_decline, :free},
    {"never paid, no card", %BillingAccount{}, @no_decline, :free},
    {"never paid, card on file", %BillingAccount{card_payment_method_id: @card}, @no_decline, :free},
    {"never paid, card on file, a declined charge", %BillingAccount{card_payment_method_id: @card}, @declined, :free},
    {"never paid, next charge free (100% code)", %BillingAccount{}, @free_code, :free},
    {"never paid, an old trial date is ignored", %BillingAccount{trial_ends_on: ~D[2026-11-30]}, @no_decline, :free},
    {"paid through the future", %BillingAccount{paid_through: ~D[2026-10-30]}, @no_decline, :active},
    {"paid through today", %BillingAccount{paid_through: ~D[2026-10-25]}, @no_decline, :active},
    {"paid through yesterday (grace)", %BillingAccount{paid_through: ~D[2026-10-24]}, @no_decline,
     {:past_due, ~D[2026-10-25]}},
    {"paid through two days ago (past grace)", %BillingAccount{paid_through: ~D[2026-10-23]}, @no_decline, :free},
    {"hold wins over a future paid_through and comped",
     %BillingAccount{held_on: @today, paid_through: ~D[2026-11-30], comped: true}, @no_decline, {:paused, :hold}},
    {"comped alone", %BillingAccount{comped: true}, @no_decline, :comped},
    {"cancelled, inside its access window",
     %BillingAccount{paid_through: ~D[2026-10-31], cancelled_on: ~D[2026-10-01], access_until: ~D[2026-10-31]},
     @no_decline, {:cancelled, ~D[2026-10-31]}},
    {"cancelled, access ended yesterday",
     %BillingAccount{paid_through: ~D[2026-10-24], cancelled_on: ~D[2026-10-01], access_until: ~D[2026-10-24]},
     @no_decline, :free},
    {"cancelled with no access window (hand edit)",
     %BillingAccount{paid_through: ~D[2026-10-30], cancelled_on: ~D[2026-10-01]}, @no_decline, :free}
  ]

  describe "of/3" do
    for {label, account, facts, expected} <- @rows do
      @account account
      @facts facts
      @expected expected
      test label do
        assert Standing.of(@account, @facts, @today) == @expected
      end
    end
  end

  test "grace_days/0 is 1 and trial_days/0 is gone" do
    assert Standing.grace_days() == 1
    Code.ensure_loaded!(Standing)
    refute function_exported?(Standing, :trial_days, 0)
  end

  test "kinds/0 lists exactly the six standing kinds, Free first" do
    assert Standing.kinds() == [:free, :active, :past_due, :cancelled, :comped, :paused]
  end

  test "pause_reasons/0 is only the hold" do
    assert Standing.pause_reasons() == [:hold]
  end

  @every [:free, :active, :comped, {:past_due, @today}, {:cancelled, @today}, {:paused, :hold}]

  test "paused?/1 is true exactly for the hold" do
    assert Standing.paused?({:paused, :hold})
    for standing <- @every -- [{:paused, :hold}], do: refute(Standing.paused?(standing))
  end

  test "unlimited?/1 is true for every paying or comped standing, false for Free and the hold" do
    for standing <- [:active, {:past_due, @today}, {:cancelled, @today}, :comped],
        do: assert(Standing.unlimited?(standing), "expected #{inspect(standing)} unlimited")

    for standing <- [:free, {:paused, :hold}],
        do: refute(Standing.unlimited?(standing), "expected #{inspect(standing)} limited")
  end

  test "cancellable?/1 is true for :active and {:past_due, _} only" do
    assert Standing.cancellable?(:active)
    assert Standing.cancellable?({:past_due, @today})
    for standing <- @every -- [:active, {:past_due, @today}], do: refute(Standing.cancellable?(standing))
  end

  test "resumable?/1 is true for {:cancelled, _} only" do
    assert Standing.resumable?({:cancelled, @today})
    for standing <- @every -- [{:cancelled, @today}], do: refute(Standing.resumable?(standing))
  end

  test "kind/1 maps a standing to its kind" do
    assert Standing.kind({:past_due, @today}) == :past_due
    assert Standing.kind({:cancelled, @today}) == :cancelled
    assert Standing.kind({:paused, :hold}) == :paused
    assert Standing.kind(:free) == :free
    assert Standing.kind(:active) == :active
    assert Standing.kind(:comped) == :comped
  end

  test "card_on_file?/1 is true for a non-blank card_payment_method_id" do
    assert Standing.card_on_file?(%{card_payment_method_id: @card})
    refute Standing.card_on_file?(%{card_payment_method_id: nil})
    refute Standing.card_on_file?(%{card_payment_method_id: "  "})
  end
end
