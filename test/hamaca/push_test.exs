defmodule Hamaca.PushTest do
  use Hamaca.DataCase, async: true

  import ExUnit.CaptureLog

  alias Hamaca.Boards
  alias Hamaca.Cards
  alias Hamaca.Push
  alias Schemas.DeviceToken

  describe "register_device/3" do
    test "stores a device token for the user" do
      user = insert(:user)

      assert {:ok, %DeviceToken{} = device} = Push.register_device(user, "tok-abc")
      assert device.user_id == user.id
      assert device.token == "tok-abc"
      assert device.platform == :ios
      assert device.last_registered_at
    end

    test "re-registering the same token upserts rather than duplicating" do
      user = insert(:user)

      {:ok, first} = Push.register_device(user, "tok-abc")
      {:ok, second} = Push.register_device(user, "tok-abc")

      assert first.id == second.id
      assert Repo.aggregate(DeviceToken, :count) == 1
    end

    test "a device re-registering under another account re-points user_id" do
      alice = insert(:user)
      bob = insert(:user)

      {:ok, _} = Push.register_device(alice, "tok-shared")
      {:ok, device} = Push.register_device(bob, "tok-shared")

      assert device.user_id == bob.id
      assert Repo.aggregate(DeviceToken, :count) == 1
    end

    test "rejects a blank token" do
      user = insert(:user)
      assert {:error, %Ecto.Changeset{}} = Push.register_device(user, "")
    end
  end

  describe "unregister_device/2" do
    test "deletes the user's device token" do
      user = insert(:user)
      {:ok, _} = Push.register_device(user, "tok-abc")

      assert :ok = Push.unregister_device(user, "tok-abc")
      assert Repo.aggregate(DeviceToken, :count) == 0
    end

    test "is idempotent" do
      user = insert(:user)
      assert :ok = Push.unregister_device(user, "never-registered")
    end

    test "will not delete another user's device token" do
      alice = insert(:user)
      bob = insert(:user)
      {:ok, _} = Push.register_device(alice, "tok-alice")

      assert :ok = Push.unregister_device(bob, "tok-alice")
      assert Repo.aggregate(DeviceToken, :count) == 1
    end
  end

  describe "delete_device_token/1" do
    test "prunes the row regardless of owner (adapter-facing)" do
      user = insert(:user)
      {:ok, _} = Push.register_device(user, "tok-stale")

      assert :ok = Push.delete_device_token("tok-stale")
      assert Repo.aggregate(DeviceToken, :count) == 0
    end
  end

  describe "notification_statuses/0" do
    test "is the awaiting-human status set owned by Schemas.Card" do
      assert Push.notification_statuses() == Schemas.Card.awaiting_human_statuses()
      assert Push.notification_statuses() == [:needs_input, :in_review]
    end
  end

  describe "muted boards (RE406)" do
    # A board with one stage, one `:working` card, and `n` resolved human members.
    defp board_with_members(n) do
      board = insert(:board)
      stage = insert(:stage, board: board)
      card = insert(:card, stage: stage, status: :working)
      users = for _ <- 1..n, do: insert(:user)
      for u <- users, do: insert(:membership, board: board, user: u)
      %{board: board, card: card, users: users}
    end

    defp with_device(user, token) do
      {:ok, _} = Push.register_device(user, token)
      user
    end

    defp mute(user, board, muted \\ true) do
      {:ok, ^muted} = Boards.set_muted(user, board.slug, muted)
      user
    end

    test "a muted member gets the browser broadcast but no APNs push; co-members still push" do
      %{board: board, card: card, users: [alice, bob]} = board_with_members(2)
      with_device(alice, "tok-alice")
      with_device(bob, "tok-bob")
      :ok = Push.subscribe_user(alice)
      :ok = Push.subscribe_user(bob)
      mute(alice, board)

      {:ok, _} = Cards.set_status(card, %{status: :needs_input}, :agent)

      ref = Cards.ref(board, card)
      assert_received {:push_delivered, "tok-bob", _}
      refute_received {:push_delivered, "tok-alice", _}

      for _ <- 1..2 do
        assert_received {:browser_notification, msg}
        assert msg.card_ref == ref
      end

      refute_received {:browser_notification, _}
    end

    test "mute is per board: the member's other boards still push" do
      %{board: board_a, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")
      mute(alice, board_a)

      board_b = insert(:board)
      insert(:membership, board: board_b, user: alice)
      card_b = insert(:card, stage: insert(:stage, board: board_b), status: :working)

      {:ok, _} = Cards.set_status(card_b, %{status: :in_review}, :agent)

      assert_received {:push_delivered, "tok-alice", payload}
      assert payload["kind"] == "in_review"
    end

    test "a muted board's cards don't count toward the badge of an unmuted board's push" do
      %{board: board_a, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")
      insert(:card, stage: insert(:stage, board: board_a), status: :needs_input)
      mute(alice, board_a)

      board_b = insert(:board)
      insert(:membership, board: board_b, user: alice)
      card_b = insert(:card, stage: insert(:stage, board: board_b), status: :working)

      {:ok, _} = Cards.set_status(card_b, %{status: :needs_input}, :agent)

      assert_received {:push_delivered, "tok-alice", %{"aps" => aps} = payload}
      assert aps["badge"] == 1
      assert aps["sound"] == Push.sound()
      assert aps["alert"]["title"] == "Question from the AI"
      assert payload["kind"] == "needs_input"
      assert payload["card_ref"] == Cards.ref(board_b, card_b)
      assert payload["board_slug"] == board_b.slug
    end

    test "the alert badge counts a stalled agent card (RE496)" do
      %{board: board, card: card, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")
      stalled = insert(:card, stage: insert_ai_stage(board: board), status: :working)
      insert(:card_owner, card: stalled)
      insert(:activity, card: stalled, type: :failure, text: "agent stopped")

      {:ok, _} = Cards.set_status(card, %{status: :in_review}, :agent)

      assert_received {:push_delivered, "tok-alice", %{"aps" => %{"badge" => 2}}}
    end

    test "muting drops the board from Cards.needs_you_badge_count/1; unmuting restores it" do
      %{board: board_a, users: [alice]} = board_with_members(1)
      insert(:card, stage: insert(:stage, board: board_a), status: :needs_input)

      assert Cards.needs_you_badge_count(alice) == 1
      mute(alice, board_a)
      assert Cards.needs_you_badge_count(alice) == 0
      mute(alice, board_a, false)
      assert Cards.needs_you_badge_count(alice) == 1
    end

    test "muting with duplicate membership rows still drops the board from the count" do
      user = insert(:user)
      board = insert(:board)
      insert(:membership, board: board, user: user)
      insert(:membership, board: board, user: user)
      insert(:card, stage: insert(:stage, board: board), status: :needs_input)

      assert {:ok, true} = Boards.set_muted(user, board.slug, true)
      assert Cards.needs_you_badge_count(user) == 0
    end

    test "unmuting a board resumes APNs pushes" do
      %{board: board, card: card, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")
      mute(alice, board)
      mute(alice, board, false)

      {:ok, _} = Cards.set_status(card, %{status: :needs_input}, :agent)

      assert_received {:push_delivered, "tok-alice", _}
    end

    test "a muted member with no device token still gets the browser broadcast" do
      %{board: board, card: card, users: [alice]} = board_with_members(1)
      :ok = Push.subscribe_user(alice)
      mute(alice, board)

      {:ok, _} = Cards.set_status(card, %{status: :needs_input}, :agent)

      assert_received {:browser_notification, _}
      refute_received {:push_delivered, _, _}
    end
  end

  describe "badge_changed/2 (RE496)" do
    test "a board target sends each member's own badge, badge-only, to every device" do
      %{board: board, users: [alice, bob, _carol]} = board_with_members(3)
      with_device(alice, "tok-a1")
      with_device(alice, "tok-a2")
      with_device(bob, "tok-b")

      assert :ok = Push.badge_changed(board, badge_fun: fn u -> if u.id == alice.id, do: 7, else: 2 end)

      deliveries =
        for _ <- 1..3 do
          assert_received {:push_delivered, token, payload}
          {token, payload}
        end

      refute_received {:push_delivered, _, _}

      assert Enum.sort(deliveries) == [
               {"tok-a1", %{"aps" => %{"badge" => 7}}},
               {"tok-a2", %{"aps" => %{"badge" => 7}}},
               {"tok-b", %{"aps" => %{"badge" => 2}}}
             ]

      for {_token, payload} <- deliveries do
        assert Map.keys(payload) == ["aps"]
        assert Map.keys(payload["aps"]) == ["badge"]
      end
    end

    test "mute does not suppress it" do
      %{board: board, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")
      mute(alice, board)

      assert :ok = Push.badge_changed(alice, badge_fun: fn _ -> 0 end)

      assert_received {:push_delivered, "tok-alice", %{"aps" => %{"badge" => 0}}}
      refute_received {:push_delivered, _, _}
    end

    test "a list target is de-duplicated by user" do
      %{users: [alice, bob]} = board_with_members(2)
      with_device(alice, "tok-alice")
      with_device(bob, "tok-bob")

      assert :ok = Push.badge_changed([alice, alice, bob], badge_fun: fn _ -> 1 end)

      assert_received {:push_delivered, "tok-alice", _}
      assert_received {:push_delivered, "tok-bob", _}
      refute_received {:push_delivered, _, _}
    end

    test "an unresolved invite row on the board gets nothing" do
      %{board: board, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")
      insert(:membership, board: board, user: nil, email: "invitee@example.com")

      assert :ok = Push.badge_changed(board, badge_fun: fn _ -> 1 end)

      assert_received {:push_delivered, "tok-alice", %{"aps" => %{"badge" => 1}}}
      refute_received {:push_delivered, _, _}
    end

    test "does not dispatch while inside an open transaction" do
      %{users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")

      Repo.transaction(fn ->
        assert :ok = Push.badge_changed(alice, badge_fun: fn _ -> 1 end)
      end)

      refute_received {:push_delivered, _, _}
    end

    test "an exploding adapter never fails the caller" do
      %{users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")
      config = %{Push.config() | adapter: Hamaca.Push.Delivery.DoesNotExist}

      log =
        capture_log(fn ->
          assert :ok = Push.badge_changed(alice, config: config, badge_fun: fn _ -> 1 end)
        end)

      assert log =~ "[push] dispatch failed"
    end
  end

  describe "badge_fun is required (RE496)" do
    test "badge_changed/2 without badge_fun raises in the caller" do
      %{users: [alice]} = board_with_members(1)

      assert_raise KeyError, fn -> Push.badge_changed(alice, []) end
    end

    test "card_status_changed/4 into a push status without badge_fun raises in the caller" do
      %{card: card} = board_with_members(1)

      assert_raise KeyError, fn ->
        Push.card_status_changed(%{card | status: :in_review}, :working, :agent, [])
      end
    end

    test "card_status_changed/4 into a non-push status without badge_fun raises too" do
      %{card: card} = board_with_members(1)

      assert_raise KeyError, fn ->
        Push.card_status_changed(%{card | status: :working}, :ready, :agent, [])
      end
    end
  end
end
