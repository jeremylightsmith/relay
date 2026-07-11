defmodule Relay.ContextBroadcastsTest do
  use Relay.DataCase, async: true

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Events
  alias Schemas.Board
  alias Schemas.Card

  setup do
    user = insert(:user)
    board = Boards.get_or_create_default_board(user)
    [backlog, spec | _rest] = board.stages
    :ok = Events.subscribe(board.id)
    %{user: user, board: board, backlog: backlog, spec: spec}
  end

  describe "Cards broadcasts" do
    test "create_card broadcasts {:card_upserted, card} with owners preloaded", %{backlog: backlog} do
      {:ok, %Card{id: card_id}} = Cards.create_card(backlog, %{title: "Live"})

      assert_receive {:card_upserted, %Card{id: ^card_id, title: "Live", owners: []}}
    end

    test "a failed create_card broadcasts no card event", %{backlog: backlog} do
      {:error, _changeset} = Cards.create_card(backlog, %{title: ""})

      refute_receive {:card_upserted, _card}, 100
    end

    test "update_card broadcasts {:card_upserted, card}", %{backlog: backlog} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(backlog, %{title: "Old"})

      {:ok, _card} = Cards.update_card(card, %{title: "New"})

      assert_receive {:card_upserted, %Card{id: ^card_id, title: "New"}}
    end

    test "a failed update_card broadcasts no card event beyond the create", %{backlog: backlog} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(backlog, %{title: "Keep"})
      assert_receive {:card_upserted, %Card{id: ^card_id}}

      {:error, _changeset} = Cards.update_card(card, %{title: ""})

      refute_receive {:card_upserted, _card}, 100
    end

    test "update_card with branch and plan broadcasts {:card_upserted, card} carrying them",
         %{backlog: backlog} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(backlog, %{title: "Runner"})
      assert_receive {:card_upserted, %Card{id: ^card_id}}

      {:ok, _card} = Cards.update_card(card, %{branch: "rly-9-live", plan: "Step 1: do it"})

      assert_receive {:card_upserted, %Card{id: ^card_id, branch: "rly-9-live", plan: "Step 1: do it"}}
    end

    test "set_status broadcasts {:card_upserted, card}", %{backlog: backlog} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(backlog, %{title: "Status"})

      {:ok, _card} = Cards.set_status(card, %{"status" => "working", "progress" => "40"})

      assert_receive {:card_upserted, %Card{id: ^card_id, status: :working, progress: 40}}
    end

    test "set_owners, add_owner, and remove_owner broadcast {:card_upserted, card} with owners preloaded",
         %{backlog: backlog, user: user} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(backlog, %{title: "Owned"})

      {:ok, _card} = Cards.set_owners(card, [{:user, user.id}])
      assert_receive {:card_upserted, %Card{id: ^card_id, owners: [%{actor_type: :user}]}}

      {:ok, _card} = Cards.add_owner(card, :agent)
      assert_receive {:card_upserted, %Card{id: ^card_id, owners: [%{actor_type: :agent}]}}

      {:ok, _card} = Cards.remove_owner(card, :agent)
      assert_receive {:card_upserted, %Card{id: ^card_id, owners: []}}
    end

    test "request_input broadcasts the blocked card and both timeline entries", %{spec: spec} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(spec, %{title: "Blocked"})

      {:ok, _blocked} = Cards.request_input(card, "Which region?")

      assert_receive {:card_upserted, %Card{id: ^card_id, status: :needs_input, blocked_since: %DateTime{}}}
      assert_receive {:timeline_appended, ^card_id, %Schemas.Comment{body: "Which region?"}}

      assert_receive {:timeline_appended, ^card_id,
                      %Schemas.Activity{type: :needs_input, meta: %{"question" => "Which region?"}}}
    end

    test "answer_input broadcasts the resumed card and the answer", %{user: user, spec: spec} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(spec, %{title: "Answer me"})
      {:ok, blocked} = Cards.request_input(card, "Ready?")

      {:ok, _answered} = Cards.answer_input(blocked, "Yes — go ahead", {:user, user.id})

      assert_receive {:card_upserted, %Card{id: ^card_id, status: :queued, blocked_since: nil}}
      assert_receive {:timeline_appended, ^card_id, %Schemas.Comment{body: "Yes — go ahead"}}
      assert_receive {:timeline_appended, ^card_id, %Schemas.Activity{type: :input_answered}}
    end

    test "move_card broadcasts {:card_moved, moved, from_stage_id}", %{backlog: backlog, spec: spec} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(backlog, %{title: "Mover"})
      backlog_id = backlog.id
      spec_id = spec.id

      {:ok, _moved} = Cards.move_card(card, spec, 0)

      assert_receive {:card_moved, %Card{id: ^card_id, stage_id: ^spec_id, owners: []}, ^backlog_id}
    end

    test "a within-stage reorder broadcasts {:card_moved, moved, same_stage_id}", %{backlog: backlog} do
      {:ok, _first} = Cards.create_card(backlog, %{title: "First"})
      {:ok, %Card{id: card_id} = second} = Cards.create_card(backlog, %{title: "Second"})
      backlog_id = backlog.id

      {:ok, _moved} = Cards.move_card(second, backlog, 0)

      assert_receive {:card_moved, %Card{id: ^card_id, stage_id: ^backlog_id}, ^backlog_id}
    end
  end

  describe "Activity broadcasts" do
    test "add_comment broadcasts {:timeline_appended, card_id, comment}", %{backlog: backlog} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(backlog, %{title: "Talk"})

      {:ok, %{id: comment_id}} = Activity.add_comment(card, %{actor: :agent, body: "hello"})

      assert_receive {:timeline_appended, ^card_id, %Schemas.Comment{id: ^comment_id, body: "hello"}}
    end

    test "a failed add_comment broadcasts nothing new", %{backlog: backlog} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(backlog, %{title: "Quiet"})
      assert_receive {:timeline_appended, ^card_id, _entry}

      {:error, _changeset} = Activity.add_comment(card, %{actor: :agent, body: ""})

      refute_receive {:timeline_appended, _card_id, _entry}, 100
    end

    test "log broadcasts {:timeline_appended, card_id, entry}", %{backlog: backlog} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(backlog, %{title: "Log"})

      {:ok, %{id: entry_id}} = Activity.log(card, %{type: :commented, actor: :agent})

      assert_receive {:timeline_appended, ^card_id, %Schemas.Activity{id: ^entry_id, type: :commented}}
    end

    test "card mutations that log also broadcast the timeline entry (create -> :created)",
         %{backlog: backlog} do
      {:ok, %Card{id: card_id}} = Cards.create_card(backlog, %{title: "Created"})

      assert_receive {:timeline_appended, ^card_id, %Schemas.Activity{type: :created}}
    end
  end

  describe "Boards broadcasts" do
    test "enable_lane broadcasts {:stages_changed, board_id} only when it creates the lane",
         %{board: board} do
      board_id = board.id
      code = Enum.find(board.stages, &(&1.name == "Code"))

      {:ok, _review} = Boards.enable_lane(code, :review)
      assert_receive {:stages_changed, ^board_id}

      {:ok, _existing} = Boards.enable_lane(code, :review)
      refute_receive {:stages_changed, ^board_id}, 100
    end

    test "disable_lane broadcasts only when it actually removes the lane", %{board: board} do
      board_id = board.id
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, _review} = Boards.enable_lane(code, :review)
      assert_receive {:stages_changed, ^board_id}

      {:ok, :disabled} = Boards.disable_lane(code, :review)
      assert_receive {:stages_changed, ^board_id}

      {:ok, :not_enabled} = Boards.disable_lane(code, :review)
      refute_receive {:stages_changed, ^board_id}, 100
    end

    test "update_board broadcasts {:board_updated, board}", %{board: board} do
      {:ok, %Board{id: board_id}} = Boards.update_board(board, %{name: "Live rename"})

      assert_receive {:board_updated, %Board{id: ^board_id, name: "Live rename"}}
    end

    test "a failed update_board broadcasts no board event", %{board: board} do
      {:error, _changeset} = Boards.update_board(board, %{name: "   "})

      refute_receive {:board_updated, _board}, 100
    end
  end
end
