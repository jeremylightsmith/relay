defmodule Relay.BillingTest do
  use Relay.DataCase, async: true

  alias Relay.Billing
  alias Relay.Billing.Standing

  describe "enabled?/0" do
    test "is false unless :billing_enabled is put" do
      refute Billing.enabled?()
    end

    test "is true once :billing_enabled is put to true" do
      Process.put(:billing_enabled, true)
      assert Billing.enabled?()
    end
  end

  test "price_cents/0 defaults to 2000" do
    assert Billing.price_cents() == 2000
  end

  test "topic/1 is billing:<user_id>" do
    assert Billing.topic(42) == "billing:42"
  end

  describe "ensure_trial/2" do
    test "creates the account with a trial ending 30 days out" do
      user = insert(:user)

      assert {:ok, account} = Billing.ensure_trial(user, ~D[2026-03-04])
      assert account.user_id == user.id
      assert account.trial_ends_on == ~D[2026-04-03]
    end

    test "never moves an existing trial date" do
      user = insert(:user)
      {:ok, _} = Billing.ensure_trial(user, ~D[2026-03-04])

      assert {:ok, account} = Billing.ensure_trial(user.id, ~D[2026-03-20])
      assert account.trial_ends_on == ~D[2026-04-03]
      assert Repo.aggregate(Schemas.BillingAccount, :count) == 1
    end

    test "fills in a trial on an existing account that has none" do
      account = insert(:billing_account, trial_ends_on: nil)

      assert {:ok, account} = Billing.ensure_trial(account.user_id, ~D[2026-03-04])
      assert account.trial_ends_on == ~D[2026-04-03]
    end
  end

  test "get_account/1 is nil for a user with no account" do
    assert Billing.get_account(insert(:user)) == nil
  end

  describe "board_paused?/1 and board_notice/1" do
    setup do
      board = insert(:board)
      %{board: board}
    end

    test "an owner paid through two days ago pauses the board", %{board: board} do
      Process.put(:billing_enabled, true)
      insert(:billing_account, user: board.owner, paid_through: Date.add(Date.utc_today(), -2))

      assert Billing.board_paused?(board)
      assert Billing.board_paused?(board.id)
      assert Billing.board_notice(board) == :paused
    end

    test "with billing disabled nothing is paused or noticed", %{board: board} do
      insert(:billing_account, user: board.owner, paid_through: Date.add(Date.utc_today(), -2))

      refute Billing.board_paused?(board)
      assert Billing.board_notice(board) == nil
    end

    test "an owner in grace is past due, not paused", %{board: board} do
      Process.put(:billing_enabled, true)
      insert(:billing_account, user: board.owner, paid_through: Date.add(Date.utc_today(), -1))

      assert Billing.board_notice(board) == :past_due
      refute Billing.board_paused?(board)
    end

    test "an active owner's board has no notice", %{board: board} do
      Process.put(:billing_enabled, true)
      insert(:billing_account, user: board.owner, paid_through: Date.add(Date.utc_today(), 5))

      refute Billing.board_paused?(board)
      assert Billing.board_notice(board) == nil
    end
  end

  describe "cancel/2 and resume/2" do
    test "cancelling an active plan keeps access through paid_through; resuming clears it" do
      today = Date.utc_today()
      paid_through = Date.add(today, 10)
      account = insert(:billing_account, paid_through: paid_through, billing_day: 3)
      user = account.user
      user_id = user.id
      :ok = Billing.subscribe(user_id)

      assert {:ok, cancelled} = Billing.cancel(user, today)
      assert cancelled.cancelled_on == today
      assert cancelled.access_until == paid_through
      assert Billing.standing(user, today) == {:cancelled, paid_through}
      assert_receive {:billing_changed, ^user_id}

      assert {:ok, resumed} = Billing.resume(user, today)
      assert resumed.cancelled_on == nil
      assert resumed.access_until == nil
      assert resumed.billing_day == 3
      assert Billing.standing(user, today) == :active
      assert_receive {:billing_changed, ^user_id}
    end

    test "cancelling a trial keeps access through the trial's end" do
      today = Date.utc_today()
      account = insert(:billing_account, trial_ends_on: Date.add(today, 5))

      assert {:ok, cancelled} = Billing.cancel(account.user, today)
      assert cancelled.access_until == account.trial_ends_on
    end

    test "a paused account is not cancellable" do
      today = Date.utc_today()
      account = insert(:billing_account, paid_through: Date.add(today, -5))

      assert Billing.standing(account.user, today) == {:paused, :unpaid}
      assert Billing.cancel(account.user, today) == {:error, :not_cancellable}
    end

    test "an active, not cancelled account is not resumable" do
      today = Date.utc_today()
      account = insert(:billing_account, paid_through: Date.add(today, 10))

      assert Billing.resume(account.user, today) == {:error, :not_resumable}
    end
  end

  test "a declined first charge after the trial pauses a card-on-file account" do
    account =
      insert(:billing_account,
        trial_ends_on: ~D[2026-08-11],
        paid_through: nil,
        card_payment_method_id: "pm_card_chargeDeclined"
      )

    insert(:billing_payment_attempt, billing_account: account, status: :failed)

    assert Billing.standing(account.user, Date.add(account.trial_ends_on, 1)) == {:paused, :trial_ended}
  end

  test "an attempt-free card-on-file account past its trial awaits the first charge" do
    account = insert(:billing_account, trial_ends_on: ~D[2026-08-11], card_payment_method_id: "pm_card_visa")

    assert Billing.standing(account.user_id, ~D[2026-08-12]) == :trial
  end

  test "a user with no account stands in :trial" do
    assert Billing.standing(insert(:user), ~D[2026-08-12]) == :trial
    assert Standing.paused?(Billing.standing(insert(:user), ~D[2026-08-12])) == false
  end
end
