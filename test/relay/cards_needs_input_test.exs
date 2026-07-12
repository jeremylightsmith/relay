defmodule Relay.CardsNeedsInputTest do
  use Relay.DataCase, async: true

  import Ecto.Query

  alias Relay.Activity
  alias Relay.Cards
  alias Schemas.Card
  alias Schemas.Comment

  setup do
    board = insert(:board, key: "RLY")
    ai_stage = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 1)
    human_stage = insert(:stage, board: board, name: "Check", type: :queue, position: 2)
    %{board: board, ai_stage: ai_stage, human_stage: human_stage}
  end

  describe "request_input/3" do
    test "sets :needs_input, stamps blocked_since, and records the question twice over",
         %{ai_stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Ship exports"})

      assert {:ok, %Card{} = blocked} = Cards.request_input(card, "Which region?")

      assert blocked.status == :needs_input
      assert %DateTime{} = blocked.blocked_since
      assert DateTime.diff(DateTime.utc_now(), blocked.blocked_since, :second) in 0..5

      timeline = Activity.list_timeline(blocked)

      assert %Comment{actor_type: :agent} =
               Enum.find(timeline, &match?(%Comment{body: "Which region?"}, &1))

      assert %Schemas.Activity{actor_type: :agent, meta: %{"question" => "Which region?"}} =
               Enum.find(timeline, &match?(%Schemas.Activity{type: :needs_input}, &1))
    end

    test "tags its question comment with kind :question", %{ai_stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Ship exports"})

      {:ok, blocked} = Cards.request_input(card, "Which colour?")

      assert [%Comment{kind: :question, body: "Which colour?"}] = Activity.list_conversation(blocked)
    end

    test "attributes the question to a user actor", %{ai_stage: stage} do
      user = insert(:user)
      {:ok, card} = Cards.create_card(stage, %{title: "Human asks"})

      {:ok, blocked} = Cards.request_input(card, "Blue or green?", {:user, user.id})

      entry =
        blocked
        |> Activity.list_timeline()
        |> Enum.find(&match?(%Schemas.Activity{type: :needs_input}, &1))

      assert entry.actor_type == :user
      assert entry.user_id == user.id
    end

    test "asking again keeps the original blocked_since and appends the new question last",
         %{ai_stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Twice"})
      {:ok, card} = Cards.request_input(card, "First question?")
      first_blocked_since = card.blocked_since

      {:ok, card} = Cards.request_input(card, "Second question?")

      assert card.status == :needs_input
      assert card.blocked_since == first_blocked_since

      questions =
        card
        |> Activity.list_timeline()
        |> Enum.filter(&match?(%Schemas.Activity{type: :needs_input}, &1))
        |> Enum.map(& &1.meta["question"])

      assert questions == ["First question?", "Second question?"]
    end

    test "blocked_since supports querying blocked cards and their age", %{ai_stage: stage} do
      {:ok, blocked} = Cards.create_card(stage, %{title: "Blocked"})
      {:ok, blocked} = Cards.request_input(blocked, "Which region?")
      {:ok, _free} = Cards.create_card(stage, %{title: "Free"})

      blocked_ids = Repo.all(from c in Card, where: not is_nil(c.blocked_since), select: c.id)

      assert blocked_ids == [blocked.id]
      assert DateTime.diff(DateTime.utc_now(), blocked.blocked_since, :second) >= 0
    end

    test "with a list of questions: blocks the card and records structured + flattened meta",
         %{ai_stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Ship exports"})

      questions = [
        %{"prompt" => "Which timezone?", "options" => ["Billing", "Viewer"], "allow_text" => true},
        %{"prompt" => "Any size limit?"}
      ]

      assert {:ok, %Card{status: :needs_input} = blocked} = Cards.request_input(card, questions, :agent)

      entry =
        blocked
        |> Activity.list_timeline()
        |> Enum.find(&match?(%Schemas.Activity{type: :needs_input}, &1))

      # structured payload, normalized (defaults filled, unknown keys dropped)
      assert entry.meta["questions"] == [
               %{"prompt" => "Which timezone?", "options" => ["Billing", "Viewer"], "allow_text" => true},
               %{"prompt" => "Any size limit?", "options" => [], "allow_text" => true}
             ]

      # flattened rendering, mirrored into meta["question"] for back-compat (board preview + panel)
      flat = "1. Which timezone?\n   a) Billing\n   b) Viewer\n2. Any size limit?"
      assert entry.meta["question"] == flat

      # one :question-kind comment whose body is the flattened text
      assert [%Comment{kind: :question, body: ^flat}] = Activity.list_conversation(blocked)
    end

    test "list normalization fills defaults: missing options -> [], missing allow_text -> true",
         %{ai_stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Defaults"})

      {:ok, blocked} = Cards.request_input(card, [%{"prompt" => "Bare?"}], :agent)

      entry =
        blocked
        |> Activity.list_timeline()
        |> Enum.find(&match?(%Schemas.Activity{type: :needs_input}, &1))

      assert entry.meta["questions"] == [%{"prompt" => "Bare?", "options" => [], "allow_text" => true}]
    end

    test "the plain-string path still writes meta['question'] and no 'questions' key",
         %{ai_stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "String path"})

      {:ok, blocked} = Cards.request_input(card, "Just a string?", :agent)

      entry =
        blocked
        |> Activity.list_timeline()
        |> Enum.find(&match?(%Schemas.Activity{type: :needs_input}, &1))

      assert entry.meta["question"] == "Just a string?"
      refute Map.has_key?(entry.meta, "questions")
    end
  end

  describe "answer_input/3" do
    test "on an AI-meant stage: resumes :working, clears blocked_since, logs comment + entry",
         %{ai_stage: stage} do
      user = insert(:user)
      {:ok, card} = Cards.create_card(stage, %{title: "Resume"})
      {:ok, card} = Cards.request_input(card, "Which region?")

      assert {:ok, %Card{} = answered} = Cards.answer_input(card, "us-east-1", {:user, user.id})

      assert answered.status == :working
      assert answered.blocked_since == nil

      timeline = Activity.list_timeline(answered)
      answer = Enum.find(timeline, &match?(%Comment{body: "us-east-1"}, &1))
      assert answer.actor_type == :user
      assert answer.user_id == user.id

      entry = Enum.find(timeline, &match?(%Schemas.Activity{type: :input_answered}, &1))
      assert entry.actor_type == :user
      assert entry.user_id == user.id
    end

    test "on a human-meant stage: returns the card to :ready", %{human_stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Human next"})
      {:ok, card} = Cards.request_input(card, "Ready?")

      assert {:ok, %Card{status: :ready, blocked_since: nil}} =
               Cards.answer_input(card, "Yes", :agent)
    end
  end

  describe "blocked_since across the other status paths" do
    test "set_status into :needs_input stamps blocked_since without any question entry",
         %{ai_stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Manual block"})

      {:ok, blocked} = Cards.set_status(card, %{status: :needs_input})

      assert %DateTime{} = blocked.blocked_since

      refute blocked
             |> Activity.list_timeline()
             |> Enum.any?(&match?(%Schemas.Activity{type: :needs_input}, &1))
    end

    test "set_status out of :needs_input clears blocked_since", %{ai_stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Unblock"})
      {:ok, blocked} = Cards.set_status(card, %{status: :needs_input})

      {:ok, unblocked} = Cards.set_status(blocked, %{status: :in_review})

      assert unblocked.blocked_since == nil
    end

    test "a same-status re-set while blocked keeps blocked_since", %{ai_stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Hold"})
      {:ok, blocked} = Cards.set_status(card, %{status: :needs_input})

      {:ok, still_blocked} = Cards.set_status(blocked, %{status: :needs_input})

      assert still_blocked.blocked_since == blocked.blocked_since
    end

    test "approve into a work-type stage keeps :needs_input (ADR 0003 — valid there so a dragged blocked card doesn't drop its question)",
         %{board: board} do
      gate = insert(:stage, board: board, name: "Gate", position: 3, type: :review)
      next = insert(:stage, board: board, name: "Deploy", position: 4, type: :work, ai_enabled: true)
      {:ok, card} = Cards.create_card(gate, %{title: "Gated"})
      {:ok, blocked} = Cards.request_input(card, "Approve the config?")

      {:ok, approved} = Cards.approve(blocked)

      assert approved.stage_id == next.id
      assert approved.status == :needs_input
      assert approved.blocked_since
    end

    test "approve into a queue-type stage clears :needs_input (invalid there, snaps to the default)",
         %{board: board} do
      gate = insert(:stage, board: board, name: "Gate", position: 3, type: :review)
      next = insert(:stage, board: board, name: "Backlog", position: 4, type: :queue)
      {:ok, card} = Cards.create_card(gate, %{title: "Gated"})
      {:ok, blocked} = Cards.request_input(card, "Approve the config?")

      {:ok, approved} = Cards.approve(blocked)

      assert approved.stage_id == next.id
      assert approved.status == :ready
      assert approved.blocked_since == nil
    end
  end
end
