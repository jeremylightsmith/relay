defmodule Relay.Push.TriggerTest do
  # Not async: several tests swap the Relay.Push adapter via Application.put_env.
  use Relay.DataCase, async: false

  import ExUnit.CaptureLog

  alias Relay.Cards
  alias Relay.Push
  alias Relay.Push.TaskSupervisor

  # A board with one stage, one card, and `n` resolved human members.
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

  describe "fires on the edge into a push-worthy status" do
    test "entering :needs_input delivers to each member's device" do
      %{board: board, card: card, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")

      {:ok, _} = Cards.set_status(card, %{status: :needs_input}, :agent)

      assert_received {:push_delivered, "tok-alice", payload}
      assert payload["kind"] == "needs_input"
      assert payload["aps"]["alert"]["title"] == "Question from the AI"
      assert payload["aps"]["alert"]["body"] == "#{board.key}-#{card.ref_number}: #{card.title}"
      assert payload["card_ref"] == "#{board.key}-#{card.ref_number}"
      assert payload["board_slug"] == board.slug
      assert payload["aps"]["sound"] == "default"
      assert payload["aps"]["badge"] == 1
    end

    test "entering :in_review uses the review copy" do
      %{card: card, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")

      {:ok, _} = Cards.set_status(card, %{status: :in_review}, :agent)

      assert_received {:push_delivered, "tok-alice", payload}
      assert payload["kind"] == "in_review"
      assert payload["aps"]["alert"]["title"] == "Ready for your review"
    end

    test "the badge is the recipient's own cross-board needs-you count" do
      %{board: board, card: card, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")

      other_board = insert(:board)
      insert(:membership, board: other_board, user: alice)
      insert(:card, stage: insert(:stage, board: other_board), status: :in_review)
      insert(:card, stage: insert(:stage, board: board), status: :needs_input)

      {:ok, _} = Cards.set_status(card, %{status: :needs_input}, :agent)

      # the two pre-seeded cards + the one just triggered
      assert_received {:push_delivered, "tok-alice", %{"aps" => %{"badge" => 3}}}
    end
  end

  describe "does not fire" do
    test "on a same-status re-set (level, not edge)" do
      %{card: card, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")

      {:ok, card} = Cards.set_status(card, %{status: :needs_input}, :agent)
      assert_received {:push_delivered, "tok-alice", _}

      {:ok, _} = Cards.set_status(card, %{status: :needs_input}, :agent)
      refute_received {:push_delivered, _, _}
    end

    test "on a transition into a non-push status" do
      %{card: card, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")

      {:ok, card} = Cards.set_status(card, %{status: :ready}, :agent)
      refute_received {:push_delivered, _, _}

      {:ok, _} = Cards.set_status(card, %{status: :working}, :agent)
      refute_received {:push_delivered, _, _}
    end

    test "when the update fails" do
      %{card: card, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")

      assert {:error, %Ecto.Changeset{}} = Cards.set_status(card, %{status: :bogus}, :agent)
      refute_received {:push_delivered, _, _}
    end
  end

  describe "recipients" do
    test "every human member gets one push per device" do
      %{card: card, users: [alice, bob]} = board_with_members(2)
      with_device(alice, "tok-alice-phone")
      with_device(alice, "tok-alice-ipad")
      with_device(bob, "tok-bob")

      {:ok, _} = Cards.set_status(card, %{status: :in_review}, :agent)

      assert_received {:push_delivered, "tok-alice-phone", _}
      assert_received {:push_delivered, "tok-alice-ipad", _}
      assert_received {:push_delivered, "tok-bob", _}
    end

    test "the acting user is skipped, others still notified" do
      %{card: card, users: [alice, bob]} = board_with_members(2)
      with_device(alice, "tok-alice")
      with_device(bob, "tok-bob")

      {:ok, _} = Cards.set_status(card, %{status: :in_review}, {:user, alice.id})

      assert_received {:push_delivered, "tok-bob", _}
      refute_received {:push_delivered, "tok-alice", _}
    end

    test "the :agent actor excludes nobody" do
      %{card: card, users: [alice, bob]} = board_with_members(2)
      with_device(alice, "tok-alice")
      with_device(bob, "tok-bob")

      {:ok, _} = Cards.set_status(card, %{status: :in_review}, :agent)

      assert_received {:push_delivered, "tok-alice", _}
      assert_received {:push_delivered, "tok-bob", _}
    end

    test "unresolved invite rows are skipped" do
      %{board: board, card: card, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")
      insert(:membership, board: board, user: nil, email: "invited@example.com")

      {:ok, _} = Cards.set_status(card, %{status: :in_review}, :agent)

      assert_received {:push_delivered, "tok-alice", _}
      refute_received {:push_delivered, _, _}
    end

    test "a member with no registered device is simply skipped" do
      %{card: card, users: [_alice]} = board_with_members(1)

      assert {:ok, _} = Cards.set_status(card, %{status: :in_review}, :agent)
      refute_received {:push_delivered, _, _}
    end
  end

  describe "fire-and-forget" do
    # A broken adapter, without defining a second module in this file (AGENTS.md
    # forbids that): a module that does not exist raises UndefinedFunctionError
    # at the `adapter.deliver/2` call — exactly the blast radius we need contained.
    # Wrapped in capture_log both to silence the expected "[push] dispatch failed"
    # error line and to assert `safely/1` actually logged it.
    test "an exploding adapter never fails set_status" do
      %{card: card, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")

      previous = Application.get_env(:relay, Push)

      Application.put_env(
        :relay,
        Push,
        Keyword.put(previous, :adapter, Relay.Push.Delivery.DoesNotExist)
      )

      on_exit(fn -> Application.put_env(:relay, Push, previous) end)

      log =
        capture_log(fn ->
          assert {:ok, updated} = Cards.set_status(card, %{status: :needs_input}, :agent)
          assert updated.status == :needs_input
        end)

      assert log =~ "[push] dispatch failed"
    end

    # The async branch (`config :relay, Relay.Push, async: true`, what production
    # runs) dispatches through `Relay.Push.TaskSupervisor`. If that named process
    # is ever unavailable, `Task.Supervisor.start_child/2` exits (:noproc) rather
    # than returning an error tuple — this proves `dispatch/1` contains that exit
    # too, not just exceptions raised inside the dispatched fun.
    test "the async branch never fails set_status when its supervisor is unavailable" do
      %{card: card, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")

      previous = Application.get_env(:relay, Push)
      Application.put_env(:relay, Push, Keyword.put(previous, :async, true))
      on_exit(fn -> Application.put_env(:relay, Push, previous) end)

      :ok = Supervisor.terminate_child(Relay.Supervisor, TaskSupervisor)
      on_exit(fn -> Supervisor.restart_child(Relay.Supervisor, TaskSupervisor) end)

      assert {:ok, updated} = Cards.set_status(card, %{status: :needs_input}, :agent)
      assert updated.status == :needs_input
    end
  end

  describe "card_status_changed/3 directly" do
    test "returns :ok and does nothing for a non-push status" do
      %{card: card, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")

      assert :ok = Push.card_status_changed(%{card | status: :working}, :ready, :agent)
      refute_received {:push_delivered, _, _}
    end
  end
end
