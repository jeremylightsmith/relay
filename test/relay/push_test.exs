defmodule Relay.PushTest do
  use Relay.DataCase, async: true

  alias Relay.Push
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

  describe "needs_you_count/1" do
    test "counts needs_input and in_review cards across the user's boards" do
      user = insert(:user)
      board_a = insert(:board)
      board_b = insert(:board)
      insert(:membership, board: board_a, user: user)
      insert(:membership, board: board_b, user: user)

      stage_a = insert(:stage, board: board_a)
      stage_b = insert(:stage, board: board_b)

      insert(:card, stage: stage_a, status: :needs_input)
      insert(:card, stage: stage_a, status: :in_review)
      insert(:card, stage: stage_b, status: :needs_input)

      assert Push.needs_you_count(user) == 3
    end

    test "excludes other statuses, archived cards, and boards the user is not on" do
      user = insert(:user)
      board = insert(:board)
      insert(:membership, board: board, user: user)
      stage = insert(:stage, board: board)

      insert(:card, stage: stage, status: :ready)
      insert(:card, stage: stage, status: :working)

      insert(:card,
        stage: stage,
        status: :in_review,
        archived_at: DateTime.truncate(DateTime.utc_now(), :second)
      )

      other_stage = insert(:stage)
      insert(:card, stage: other_stage, status: :needs_input)

      assert Push.needs_you_count(user) == 0
    end

    test "an unresolved invite row does not grant a count" do
      user = insert(:user)
      board = insert(:board)
      insert(:membership, board: board, user: nil, email: user.email)
      stage = insert(:stage, board: board)
      insert(:card, stage: stage, status: :needs_input)

      assert Push.needs_you_count(user) == 0
    end

    test "excludes needs_input/in_review cards on an archived board" do
      user = insert(:user)
      board = insert(:board, archived_at: DateTime.truncate(DateTime.utc_now(), :second))
      insert(:membership, board: board, user: user)
      stage = insert(:stage, board: board)

      insert(:card, stage: stage, status: :needs_input)
      insert(:card, stage: stage, status: :in_review)

      assert Push.needs_you_count(user) == 0
    end
  end
end
