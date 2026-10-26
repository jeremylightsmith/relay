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

  test "format_cents/1 renders dollars with two-digit cents" do
    assert Billing.format_cents(2000) == "$20.00"
    assert Billing.format_cents(5) == "$0.05"
    assert Billing.format_cents(123_456) == "$1234.56"
  end

  describe "ensure_account/1" do
    test "creates one account with no trial date, twice over" do
      user = insert(:user)

      assert {:ok, %Schemas.BillingAccount{} = first} = Billing.ensure_account(user)
      assert {:ok, %Schemas.BillingAccount{} = second} = Billing.ensure_account(user.id)
      assert first.id == second.id
      assert first.user_id == user.id
      assert second.trial_ends_on == nil
      assert Repo.aggregate(Schemas.BillingAccount, :count) == 1
    end
  end

  test "ensure_trial/2 is gone" do
    Code.ensure_loaded!(Billing)
    refute function_exported?(Billing, :ensure_trial, 2)
  end

  test "get_account/1 is nil for a user with no account" do
    assert Billing.get_account(insert(:user)) == nil
  end

  test "free_board_limit/0 is 1" do
    assert Billing.free_board_limit() == 1
  end

  # A live board of `owner`, last updated a day ago less `older:` seconds.
  defp board!(owner, name, attrs \\ []) do
    updated_at = DateTime.add(DateTime.utc_now(:second), -86_400 - Keyword.get(attrs, :older, 0))
    insert(:board, [owner: owner, name: name, updated_at: updated_at] ++ Keyword.delete(attrs, :older))
  end

  defp card_on!(board, updated_at \\ DateTime.utc_now(:second)) do
    insert(:card, stage: insert(:stage, board: board), updated_at: updated_at)
  end

  # Scenario 8's owner: Free, boards A, B, C, a card on B the newest activity.
  defp free_owner_of_three do
    owner = insert(:user)
    a = board!(owner, "A", older: 30)
    b = board!(owner, "B", older: 20)
    c = board!(owner, "C", older: 10)
    b_card = card_on!(b)
    %{owner: owner, a: a, b: b, c: c, b_card: b_card}
  end

  describe "the Free limit and the gate" do
    setup do
      Process.put(:billing_enabled, true)
      :ok
    end

    test "the board with the newest card change is editable; the others are read-only" do
      %{owner: owner, a: a, b: b, c: c} = free_owner_of_three()

      assert Billing.editable_board_id(owner.id) == b.id
      assert Billing.board_paused?(a)
      assert Billing.board_paused?(c.id)
      refute Billing.board_paused?(b)
      refute Billing.board_paused?(b.id)
    end

    test "with no cards the most recently updated board is editable; a tie goes to the higher id" do
      owner = insert(:user)
      _a = board!(owner, "A", older: 10)
      b = board!(owner, "B")
      assert Billing.editable_board_id(owner.id) == b.id

      tied = insert(:user)
      first = board!(tied, "First")
      second = board!(tied, "Second")
      assert second.id > first.id
      assert Billing.editable_board_id(tied.id) == second.id
    end

    test "archived and example boards are never counted, never editable and never read-only" do
      owner = insert(:user)
      archived = board!(owner, "Archived", archived_at: DateTime.utc_now(:second))
      card_on!(archived)
      example = board!(owner, "Example", example_template: "bare")
      card_on!(example, DateTime.add(DateTime.utc_now(:second), -60))
      live = board!(owner, "Live", older: 100)

      assert Billing.editable_board_id(owner.id) == live.id
      refute Billing.board_paused?(live)
      refute Billing.board_paused?(example)
      refute Billing.board_paused?(archived)
    end

    test "archiving the editable board hands the slot to the next" do
      owner = insert(:user)
      a = board!(owner, "A")
      b = board!(owner, "B", older: 10)
      assert Billing.editable_board_id(owner.id) == a.id

      Repo.update!(Ecto.Changeset.change(a, archived_at: DateTime.utc_now(:second)))

      assert Billing.editable_board_id(owner.id) == b.id
      refute Billing.board_paused?(b)
    end

    test "a card's own archived_at does not hide its activity" do
      owner = insert(:user)
      _a = board!(owner, "A")
      b = board!(owner, "B", older: 10)
      card = card_on!(b)
      Repo.update!(Ecto.Changeset.change(card, archived_at: DateTime.utc_now(:second)))

      assert Billing.editable_board_id(owner.id) == b.id
    end

    test "an owner with no counted board has no editable board" do
      assert Billing.editable_board_id(insert(:user).id) == nil
    end

    test "a Free owner's only live board is neither paused nor noticed" do
      owner = insert(:user)
      only = board!(owner, "Only")

      refute Billing.board_paused?(only)
      assert Billing.board_notice(only) == nil
    end

    test "board_notice/1 names the editable board on a read-only one; hold and past due keep theirs" do
      %{a: a} = free_owner_of_three()
      assert Billing.board_notice(a) == {:free_read_only, "B"}

      held = insert(:billing_account, held_on: Date.utc_today(), hold_reason: "test")
      held_board = board!(held.user, "Held")
      assert Billing.board_notice(held_board) == :paused
      assert Billing.board_paused?(held_board)

      late = insert(:billing_account, paid_through: Date.add(Date.utc_today(), -1))
      late_board = board!(late.user, "Late")
      assert Billing.board_notice(late_board) == :past_due
      refute Billing.board_paused?(late_board)
    end

    test "paying, comped or a cancelled plan inside its window lifts the limit" do
      today = Date.utc_today()

      for attrs <- [
            [paid_through: Date.add(today, 10)],
            [comped: true],
            [paid_through: Date.add(today, 3), cancelled_on: today, access_until: Date.add(today, 3)]
          ] do
        %{owner: owner, a: a} = free_owner_of_three()
        insert(:billing_account, [user: owner] ++ attrs)

        refute Billing.board_paused?(a), "expected #{inspect(attrs)} to lift the limit"
        assert Billing.board_notice(a) == nil
        assert Billing.free_status(owner, today) == nil
      end
    end

    test "with billing disabled there is no limit, gate, notice or Free status" do
      %{owner: owner, a: a, c: c} = free_owner_of_three()
      Process.put(:billing_enabled, false)

      refute Billing.board_paused?(a)
      refute Billing.board_paused?(c.id)
      assert Billing.board_notice(a) == nil
      assert Billing.can_add_board?(owner)
      assert Billing.free_status(owner, Date.utc_today()) == nil
    end

    test "can_add_board?/1 is false only at the Free limit or on hold" do
      empty = insert(:user)
      assert Billing.can_add_board?(empty)

      one = insert(:user)
      board!(one, "One")
      refute Billing.can_add_board?(one)
      refute Billing.can_add_board?(one.id)

      mixed = insert(:user)
      board!(mixed, "Live")
      board!(mixed, "Archived", archived_at: DateTime.utc_now(:second))
      board!(mixed, "Example", example_template: "bare")
      refute Billing.can_add_board?(mixed)

      uncounted = insert(:user)
      board!(uncounted, "Archived", archived_at: DateTime.utc_now(:second))
      board!(uncounted, "Example", example_template: "starter")
      assert Billing.can_add_board?(uncounted)

      held = insert(:billing_account, held_on: Date.utc_today(), hold_reason: "test")
      refute Billing.can_add_board?(held.user)

      active = insert(:billing_account, paid_through: Date.add(Date.utc_today(), 10))
      for n <- 1..5, do: board!(active.user, "Board #{n}")
      assert Billing.can_add_board?(active.user)
    end

    test "free_status/2 lists the counted boards, editable first" do
      %{owner: owner, a: a, b: b, c: c} = free_owner_of_three()

      assert %{limit: 1, editable_board_id: b_id, over_limit?: true, boards: boards} =
               Billing.free_status(owner, Date.utc_today())

      assert b_id == b.id

      assert Enum.map(boards, &Map.delete(&1, :active_at)) == [
               %{id: b.id, slug: b.slug, name: "B", editable?: true},
               %{id: c.id, slug: c.slug, name: "C", editable?: false},
               %{id: a.id, slug: a.slug, name: "A", editable?: false}
             ]

      assert Billing.free_status(owner.id, Date.utc_today()).over_limit?
    end

    test "free_status/2 is within the limit with one board, and nil for an active owner" do
      owner = insert(:user)
      only = board!(owner, "Only")

      assert Billing.free_status(owner, Date.utc_today()) == %{
               limit: 1,
               editable_board_id: only.id,
               over_limit?: false,
               boards: [%{id: only.id, slug: only.slug, name: "Only", editable?: true, active_at: only.updated_at}]
             }

      active = insert(:billing_account, paid_through: Date.add(Date.utc_today(), 10))
      assert Billing.free_status(active.user, Date.utc_today()) == nil
    end
  end

  describe "choosing the editable board (RE471)" do
    setup do
      Process.put(:billing_enabled, true)
      :ok
    end

    test "the owner's pick wins over the most active board, in every gate" do
      %{owner: owner, a: a, b: b, c: c} = free_owner_of_three()
      c_id = c.id

      assert {:ok, %Schemas.BillingAccount{free_board_id: ^c_id}} = Billing.choose_free_board(owner, c.id)

      assert Billing.editable_board_id(owner.id) == c.id
      assert Billing.board_paused?(b)
      assert Billing.board_paused?(a.id)
      refute Billing.board_paused?(c)
      assert Billing.board_notice(b) == {:free_read_only, "C"}
    end

    test "free_status/2 lists the pick first, then by activity, each with its active_at" do
      %{owner: owner, a: a, b: b, c: c, b_card: b_card} = free_owner_of_three()
      {:ok, _} = Billing.choose_free_board(owner, c.id)

      assert %{editable_board_id: editable_id, boards: boards} = Billing.free_status(owner, Date.utc_today())
      assert editable_id == c.id
      assert Enum.map(boards, & &1.id) == [c.id, b.id, a.id]
      assert boards |> Enum.filter(& &1.editable?) |> Enum.map(& &1.id) == [c.id]
      assert Enum.all?(boards, &match?(%DateTime{}, &1.active_at))
      assert Enum.find(boards, &(&1.id == b.id)).active_at == b_card.updated_at
    end

    test "an archived pick falls back to the most active board and keeps the column" do
      %{owner: owner, b: b, c: c} = free_owner_of_three()
      {:ok, _} = Billing.choose_free_board(owner, c.id)

      {:ok, _} = Relay.Boards.archive_board(c)

      assert Billing.editable_board_id(owner.id) == b.id
      assert Billing.get_account(owner).free_board_id == c.id
    end

    test "deleting the picked board nilifies the pick" do
      %{owner: owner, b: b, c: c} = free_owner_of_three()
      {:ok, _} = Billing.choose_free_board(owner, c.id)

      Repo.delete!(c)

      assert Billing.get_account(owner).free_board_id == nil
      assert Billing.editable_board_id(owner.id) == b.id
    end

    test "a pick that changed owner no longer counts for the old owner" do
      %{owner: owner, b: b, c: c} = free_owner_of_three()
      {:ok, _} = Billing.choose_free_board(owner, c.id)
      new_owner = insert(:user)

      c = Repo.update!(Ecto.Changeset.change(c, owner_id: new_owner.id))

      assert Billing.editable_board_id(owner.id) == b.id
      assert Billing.editable_board_id(new_owner.id) == c.id
      refute Billing.board_paused?(c)
    end

    test "another user's board is refused, writing and broadcasting nothing" do
      %{owner: owner} = free_owner_of_three()
      x = board!(insert(:user), "X")
      :ok = Billing.subscribe(owner.id)

      assert Billing.choose_free_board(owner, x.id) == {:error, :not_counted}
      assert Billing.get_account(owner) == nil
      refute_receive {:billing_changed, _}
    end

    test "the owner's archived and example boards are refused" do
      owner = insert(:user)
      board!(owner, "Live")
      d = board!(owner, "D", archived_at: DateTime.utc_now(:second))
      e = board!(owner, "E", example_template: "bare")

      assert Billing.choose_free_board(owner, d.id) == {:error, :not_counted}
      assert Billing.choose_free_board(owner, e.id) == {:error, :not_counted}
    end

    test "a pick broadcasts billing_changed for the owner" do
      %{owner: owner, a: a} = free_owner_of_three()
      :ok = Billing.subscribe(owner.id)

      assert {:ok, _} = Billing.choose_free_board(owner, a.id)

      assert_receive {:billing_changed, owner_id}
      assert owner_id == owner.id
    end

    test "an active owner may pick, and pick again straight after; nothing is paused" do
      today = Date.utc_today()
      owner = insert(:user)
      insert(:billing_account, user: owner, paid_through: Date.add(today, 10), billing_day: today.day)
      a = board!(owner, "A")
      b = board!(owner, "B")
      a_id = a.id
      b_id = b.id

      assert {:ok, %{free_board_id: ^a_id}} = Billing.choose_free_board(owner, a.id)
      refute Billing.board_paused?(b)
      assert {:ok, %{free_board_id: ^b_id}} = Billing.choose_free_board(owner, b.id)
    end

    test "a Free owner with no account gets exactly one, holding the pick" do
      owner = insert(:user)
      a = board!(owner, "A")
      board!(owner, "B")

      assert {:ok, _} = Billing.choose_free_board(owner, a.id)

      assert [%Schemas.BillingAccount{free_board_id: free_board_id}] =
               Repo.all(from ba in Schemas.BillingAccount, where: ba.user_id == ^owner.id)

      assert free_board_id == a.id
    end

    test "a Free owner over the limit is prompted once" do
      %{owner: owner} = free_owner_of_three()

      assert Billing.free_board_prompt?(owner, Date.utc_today())
      assert {:ok, %Schemas.BillingAccount{}} = Billing.mark_free_board_prompted(owner)
      refute Billing.free_board_prompt?(owner, Date.utc_today())
      assert %DateTime{microsecond: {0, 0}} = Billing.get_account(owner).free_board_prompted_at
    end

    test "marking the prompt does not broadcast" do
      %{owner: owner} = free_owner_of_three()
      :ok = Billing.subscribe(owner.id)

      {:ok, _} = Billing.mark_free_board_prompted(owner)

      refute_receive {:billing_changed, _}
    end

    test "no prompt within the limit, when paying or comped, or with billing disabled" do
      today = Date.utc_today()

      one = insert(:user)
      board!(one, "Only")
      refute Billing.free_board_prompt?(one, today)

      %{owner: active} = free_owner_of_three()
      insert(:billing_account, user: active, paid_through: Date.add(today, 10), billing_day: today.day)
      refute Billing.free_board_prompt?(active, today)

      %{owner: comped} = free_owner_of_three()
      insert(:billing_account, user: comped, comped: true)
      refute Billing.free_board_prompt?(comped, today)

      %{owner: disabled} = free_owner_of_three()
      Process.put(:billing_enabled, false)
      refute Billing.free_board_prompt?(disabled, today)
    end

    test "a drop to Free after a paid period asks" do
      today = Date.utc_today()
      %{owner: owner} = free_owner_of_three()
      insert(:billing_account, user: owner, paid_through: Date.add(today, -10), free_board_prompted_at: nil)
      assert Billing.standing(owner, today) == :free

      assert Billing.free_board_prompt?(owner, today)
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

    test "a Free account is not cancellable" do
      today = Date.utc_today()
      never_paid = insert(:billing_account)
      lapsed = insert(:billing_account, paid_through: Date.add(today, -5))

      assert Billing.standing(never_paid.user, today) == :free
      assert Billing.cancel(never_paid.user, today) == {:error, :not_cancellable}
      assert Billing.standing(lapsed.user, today) == :free
      assert Billing.cancel(lapsed.user, today) == {:error, :not_cancellable}
    end

    test "a held account is not cancellable" do
      account = insert(:billing_account, held_on: Date.utc_today(), hold_reason: "test", paid_through: Date.utc_today())
      assert Billing.cancel(account.user, Date.utc_today()) == {:error, :not_cancellable}
    end

    test "an active, not cancelled account is not resumable" do
      today = Date.utc_today()
      account = insert(:billing_account, paid_through: Date.add(today, 10))

      assert Billing.resume(account.user, today) == {:error, :not_resumable}
    end
  end

  describe "native_status/2" do
    test "billing disabled answers enabled: false with no standing or through" do
      user = insert(:user)
      insert(:billing_account, user: user, paid_through: ~D[2026-05-03])

      assert Billing.native_status(user, ~D[2026-05-01]) == %{enabled: false, standing: nil, through: nil}
    end

    test "a never-paid account is Free with no through" do
      Process.put(:billing_enabled, true)
      user = insert(:user)
      insert(:billing_account, user: user, trial_ends_on: ~D[2026-11-30], paid_through: nil)

      assert Billing.native_status(user, ~D[2026-10-25]) == %{enabled: true, standing: :free, through: nil}
    end

    test "a user with no billing account is Free with no through" do
      Process.put(:billing_enabled, true)
      user = insert(:user)

      assert Billing.native_status(user, Date.utc_today()) == %{enabled: true, standing: :free, through: nil}
      assert Billing.native_status(user.id, Date.utc_today()) == %{enabled: true, standing: :free, through: nil}
    end

    test "an active plan runs through paid_through" do
      Process.put(:billing_enabled, true)
      user = insert(:user)
      insert(:billing_account, user: user, paid_through: ~D[2026-05-03])

      assert Billing.native_status(user, ~D[2026-04-20]) == %{enabled: true, standing: :active, through: ~D[2026-05-03]}
    end

    test "a past-due plan inside the grace reports paid_through" do
      Process.put(:billing_enabled, true)
      user = insert(:user)
      insert(:billing_account, user: user, paid_through: ~D[2026-05-03])

      assert Billing.native_status(user, ~D[2026-05-04]) ==
               %{enabled: true, standing: :past_due, through: ~D[2026-05-03]}
    end

    test "a cancelled plan runs through access_until" do
      Process.put(:billing_enabled, true)
      user = insert(:user)

      insert(:billing_account,
        user: user,
        paid_through: ~D[2026-05-03],
        cancelled_on: ~D[2026-04-10],
        access_until: ~D[2026-05-03]
      )

      assert Billing.native_status(user, ~D[2026-04-20]) ==
               %{enabled: true, standing: :cancelled, through: ~D[2026-05-03]}
    end

    test "a comped plan has no through" do
      Process.put(:billing_enabled, true)
      user = insert(:user)
      insert(:billing_account, user: user, comped: true, paid_through: ~D[2026-05-03])

      assert Billing.native_status(user, ~D[2026-08-01]) == %{enabled: true, standing: :comped, through: nil}
    end

    test "a held plan is paused with no through" do
      Process.put(:billing_enabled, true)
      user = insert(:user)
      insert(:billing_account, user: user, paid_through: ~D[2026-05-03], held_on: ~D[2026-05-01], hold_reason: "test")

      assert Billing.native_status(user, ~D[2026-05-02]) == %{enabled: true, standing: :paused, through: nil}
    end

    test "a lapsed paid plan is Free with no through" do
      Process.put(:billing_enabled, true)
      user = insert(:user)
      insert(:billing_account, user: user, paid_through: ~D[2026-05-03])

      assert Billing.native_status(user, ~D[2026-05-20]) == %{enabled: true, standing: :free, through: nil}
    end
  end

  test "a user with no account stands in :free" do
    assert Billing.standing(insert(:user), ~D[2026-08-12]) == :free
    assert Standing.paused?(Billing.standing(insert(:user), ~D[2026-08-12])) == false
  end
end
