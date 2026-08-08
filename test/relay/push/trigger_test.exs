defmodule Relay.Push.TriggerTest do
  use Relay.DataCase, async: true

  import ExUnit.CaptureLog

  alias Relay.Cards
  alias Relay.Push

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
      assert payload["aps"]["alert"]["body"] == "#{board.key}#{card.ref_number}: #{card.title}"
      assert payload["card_ref"] == "#{board.key}#{card.ref_number}"
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
    # A broken adapter, without defining a second module in this file (AGENTS.md forbids that):
    # a module that does not exist raises UndefinedFunctionError at the `adapter.deliver/2` call —
    # exactly the blast radius we need contained. The adapter is injected per call (ADR 0009
    # rule 1) instead of being written into application env, so this test is async-safe; the
    # containment being proven lives in Relay.Push, which is where the call is made.
    test "an exploding adapter never fails the caller" do
      %{card: card, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")

      config = %{Push.config() | adapter: Relay.Push.Delivery.DoesNotExist}

      log =
        capture_log(fn ->
          assert :ok = Push.card_status_changed(%{card | status: :needs_input}, :working, :agent, config: config)
        end)

      assert log =~ "[push] dispatch failed"
    end

    # The async branch (`config :relay, Relay.Push, async: true`, what production runs) dispatches
    # through a Task.Supervisor. If that named process is unavailable, `Task.Supervisor.start_child/2`
    # *exits* (:noproc) rather than returning an error tuple — this proves `dispatch/2` contains that
    # exit too, not just exceptions raised inside the dispatched fun. The unreachable supervisor is
    # injected by name rather than by terminating the app-wide one (ADR 0009 rule 1).
    test "the async branch never fails the caller when its task supervisor is unavailable" do
      %{card: card, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")

      config = %{Push.config() | async: true, task_supervisor: :push_task_supervisor_that_does_not_exist}

      log =
        capture_log(fn ->
          assert :ok = Push.card_status_changed(%{card | status: :needs_input}, :working, :agent, config: config)
        end)

      assert log =~ "[push] dispatch exit"
    end
  end

  describe "the real async path (Task.Supervisor actually runs the task)" do
    # Relay.Push.Delivery.Test resolves its target through `$callers`, which Task seeds with its
    # spawner — so a dispatched Task (a different process than the test) still reaches the test's
    # mailbox with no application-env key involved. Without this, async: true could only be
    # exercised by breaking the supervisor (above), never by letting a task actually deliver.
    test "a dispatched Task delivers the push back to the test process" do
      %{card: card, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")

      config = %{Push.config() | async: true}

      assert :ok = Push.card_status_changed(%{card | status: :in_review}, :working, :agent, config: config)

      assert_receive {:push_delivered, "tok-alice", payload}, 1000
      assert payload["kind"] == "in_review"
    end
  end

  describe "transactional callers (RLY-81 review fix)" do
    # Cards.set_status/3's push must never fire from inside an open transaction:
    # an uncommitted write is invisible to a Task running on another DB
    # connection (the async: true production path), and a push is irrevocable —
    # unlike a rolled-back write, it cannot be taken back once delivered.
    test "card_status_changed/3 does not dispatch while inside an open transaction" do
      %{card: card, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")

      Repo.transaction(fn ->
        assert :ok = Push.card_status_changed(%{card | status: :in_review}, :working, :agent)
      end)

      refute_received {:push_delivered, _, _}
    end

    # The canonical transactional caller: Cards.move_card/4 snaps a card's status
    # to the destination stage's default (ADR 0003) from inside its own
    # transaction. The push must still reach the recipient — just deferred until
    # after that transaction commits.
    test "moving a card into a review stage still delivers the push, once, after commit" do
      %{board: board, card: card, users: [alice]} = board_with_members(1)
      with_device(alice, "tok-alice")
      review_stage = insert(:stage, board: board, type: :review, category: :complete)

      assert {:ok, moved} = Cards.move_card(card, review_stage, 0, :agent)
      assert moved.status == :in_review

      assert_received {:push_delivered, "tok-alice", payload}
      assert payload["kind"] == "in_review"
      refute_received {:push_delivered, _, _}
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
