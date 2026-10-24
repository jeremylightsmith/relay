defmodule Relay.Billing.StandingTest do
  use ExUnit.Case, async: true

  alias Relay.Billing.Standing
  alias Schemas.BillingAccount

  @today ~D[2026-08-12]
  @card "pm_card_visa"
  @no_decline %{first_charge_declined?: false}
  @declined %{first_charge_declined?: true}

  # {label, account, facts, expected standing on @today}
  @rows [
    {"nil account", nil, @no_decline, :trial},
    {"both dates nil (pre-backfill)", %BillingAccount{}, @no_decline, :trial},
    {"trial's last day, no card", %BillingAccount{trial_ends_on: ~D[2026-08-12]}, @no_decline, :trial},
    {"trial over, no card", %BillingAccount{trial_ends_on: ~D[2026-08-11]}, @no_decline, {:paused, :trial_ended}},
    {"trial over, card on file, awaiting first charge",
     %BillingAccount{trial_ends_on: ~D[2026-08-11], card_payment_method_id: @card}, @no_decline, :trial},
    {"trial over, card on file, first charge declined",
     %BillingAccount{trial_ends_on: ~D[2026-08-11], card_payment_method_id: @card}, @declined, {:paused, :trial_ended}},
    {"paid through today", %BillingAccount{paid_through: ~D[2026-08-12]}, @no_decline, :active},
    {"paid through yesterday (grace)", %BillingAccount{paid_through: ~D[2026-08-11]}, @no_decline,
     {:past_due, ~D[2026-08-12]}},
    {"paid through two days ago", %BillingAccount{paid_through: ~D[2026-08-10]}, @no_decline, {:paused, :unpaid}},
    {"hold wins over a future paid_through and comped",
     %BillingAccount{held_on: ~D[2026-08-01], paid_through: ~D[2026-09-30], comped: true}, @no_decline, {:paused, :hold}},
    {"comped, never paid, trial long over", %BillingAccount{comped: true, trial_ends_on: ~D[2026-01-01]}, @no_decline,
     :comped},
    {"cancelled, access through today",
     %BillingAccount{paid_through: ~D[2026-08-12], cancelled_on: ~D[2026-08-01], access_until: ~D[2026-08-12]},
     @no_decline, {:cancelled, ~D[2026-08-12]}},
    {"cancelled, access ended yesterday",
     %BillingAccount{paid_through: ~D[2026-08-11], cancelled_on: ~D[2026-08-01], access_until: ~D[2026-08-11]},
     @no_decline, {:paused, :cancelled}},
    {"cancelled with no access window (hand edit)",
     %BillingAccount{paid_through: ~D[2026-08-30], cancelled_on: ~D[2026-08-01]}, @no_decline, {:paused, :cancelled}}
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

  test "trial_days/0 is 30 and grace_days/0 is 1" do
    assert Standing.trial_days() == 30
    assert Standing.grace_days() == 1
  end

  test "kinds/0 lists exactly the six standing kinds" do
    assert Standing.kinds() == [:trial, :active, :past_due, :cancelled, :comped, :paused]
  end

  test "pause_reasons/0 in order" do
    assert Standing.pause_reasons() == [:trial_ended, :unpaid, :cancelled, :hold]
  end

  @non_paused [:trial, :active, :comped, {:past_due, @today}, {:cancelled, @today}]

  test "paused?/1 is true exactly for every {:paused, reason}" do
    for reason <- Standing.pause_reasons(), do: assert(Standing.paused?({:paused, reason}))
    for standing <- @non_paused, do: refute(Standing.paused?(standing))
  end

  test "cancellable?/1 is true for :trial, :active and {:past_due, _} only" do
    assert Standing.cancellable?(:trial)
    assert Standing.cancellable?(:active)
    assert Standing.cancellable?({:past_due, @today})
    refute Standing.cancellable?(:comped)
    refute Standing.cancellable?({:cancelled, @today})
    for reason <- Standing.pause_reasons(), do: refute(Standing.cancellable?({:paused, reason}))
  end

  test "resumable?/1 is true for {:cancelled, _} only" do
    assert Standing.resumable?({:cancelled, @today})

    for standing <- [:trial, :active, :comped, {:past_due, @today} | Enum.map(Standing.pause_reasons(), &{:paused, &1})] do
      refute Standing.resumable?(standing)
    end
  end

  test "kind/1 maps a standing to its kind" do
    assert Standing.kind({:past_due, @today}) == :past_due
    assert Standing.kind({:cancelled, @today}) == :cancelled
    assert Standing.kind({:paused, :hold}) == :paused
    assert Standing.kind(:trial) == :trial
    assert Standing.kind(:active) == :active
    assert Standing.kind(:comped) == :comped
  end

  test "card_on_file?/1 is true for a non-blank card_payment_method_id" do
    assert Standing.card_on_file?(%{card_payment_method_id: @card})
    refute Standing.card_on_file?(%{card_payment_method_id: nil})
    refute Standing.card_on_file?(%{card_payment_method_id: "  "})
  end
end
