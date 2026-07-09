defmodule Relay.ActivityTest do
  use Relay.DataCase, async: true

  alias Relay.Activity
  alias Schemas.Comment

  setup do
    user = insert(:user, name: "Ada Lovelace")
    card = insert(:card)
    %{user: user, card: card}
  end

  describe "add_comment/2" do
    test "persists a user comment with the user preloaded", %{card: card, user: user} do
      assert {:ok, %Comment{} = comment} =
               Activity.add_comment(card, %{actor: {:user, user.id}, body: "Looks good"})

      assert comment.card_id == card.id
      assert comment.actor_type == :user
      assert comment.user_id == user.id
      assert comment.body == "Looks good"
      assert comment.user.name == "Ada Lovelace"
      assert Repo.get!(Comment, comment.id).body == "Looks good"
    end

    test "persists an agent comment with no user", %{card: card} do
      assert {:ok, %Comment{} = comment} =
               Activity.add_comment(card, %{actor: :agent, body: "Done — see the PR."})

      assert comment.actor_type == :agent
      assert comment.user_id == nil
      assert comment.user == nil
    end

    test "rejects a blank body and persists nothing", %{card: card, user: user} do
      assert {:error, changeset} =
               Activity.add_comment(card, %{actor: {:user, user.id}, body: ""})

      assert "can't be blank" in errors_on(changeset).body
      assert Repo.aggregate(Comment, :count) == 0
    end
  end

  describe "log/2" do
    test "persists an entry with type, meta, and actor, user preloaded", %{card: card, user: user} do
      assert {:ok, %Schemas.Activity{} = entry} =
               Activity.log(card, %{
                 type: :moved,
                 actor: {:user, user.id},
                 meta: %{"from_stage" => "Spec", "to_stage" => "Code"}
               })

      assert entry.card_id == card.id
      assert entry.type == :moved
      assert entry.actor_type == :user
      assert entry.user_id == user.id
      assert entry.user.name == "Ada Lovelace"

      assert Repo.get!(Schemas.Activity, entry.id).meta ==
               %{"from_stage" => "Spec", "to_stage" => "Code"}
    end

    test "meta defaults to an empty map and the agent actor has no user", %{card: card} do
      assert {:ok, entry} = Activity.log(card, %{type: :created, actor: :agent})

      assert entry.meta == %{}
      assert entry.actor_type == :agent
      assert entry.user_id == nil
      assert entry.user == nil
    end
  end

  describe "list_timeline/1" do
    test "merges comments and activity chronologically with users preloaded", %{card: card, user: user} do
      c1 = insert(:comment, card: card, user: user, body: "First", inserted_at: ~U[2026-07-07 10:00:10Z])
      a1 = insert(:activity, card: card, type: :created, meta: %{}, inserted_at: ~U[2026-07-07 10:00:00Z])
      a2 = insert(:activity, card: card, user: user, inserted_at: ~U[2026-07-07 10:00:20Z])
      c2 = insert(:comment, card: card, body: "Second", inserted_at: ~U[2026-07-07 10:00:30Z])

      timeline = Activity.list_timeline(card)

      assert Enum.map(timeline, &{&1.__struct__, &1.id}) == [
               {Schemas.Activity, a1.id},
               {Comment, c1.id},
               {Schemas.Activity, a2.id},
               {Comment, c2.id}
             ]

      assert [created, first_comment, moved, second_comment] = timeline
      assert created.user == nil
      assert first_comment.user.name == "Ada Lovelace"
      assert moved.user.id == user.id
      assert second_comment.user == nil
    end

    test "comments sort before activity entries at the same timestamp", %{card: card, user: user} do
      at = ~U[2026-07-07 12:00:00Z]
      comment = insert(:comment, card: card, user: user, inserted_at: at)
      entry = insert(:activity, card: card, inserted_at: at)

      assert Enum.map(Activity.list_timeline(card), &{&1.__struct__, &1.id}) == [
               {Comment, comment.id},
               {Schemas.Activity, entry.id}
             ]
    end

    test "excludes other cards' entries", %{card: card} do
      other = insert(:card)
      insert(:comment, card: other)
      insert(:activity, card: other)
      mine = insert(:comment, card: card)

      assert Enum.map(Activity.list_timeline(card), &{&1.__struct__, &1.id}) == [{Comment, mine.id}]
    end

    test "returns [] for a card with no history", %{card: card} do
      assert Activity.list_timeline(card) == []
    end
  end

  describe "list_conversation/1" do
    test "returns only comments, oldest first, with users preloaded", %{card: card, user: user} do
      c1 = insert(:comment, card: card, user: user, body: "First", inserted_at: ~U[2026-07-07 10:00:10Z])
      _a = insert(:activity, card: card, type: :created, meta: %{}, inserted_at: ~U[2026-07-07 10:00:20Z])
      c2 = insert(:comment, card: card, body: "Second", inserted_at: ~U[2026-07-07 10:00:30Z])

      conversation = Activity.list_conversation(card)

      assert Enum.all?(conversation, &match?(%Comment{}, &1))
      assert Enum.map(conversation, & &1.id) == [c1.id, c2.id]
      assert [first, second] = conversation
      assert first.user.name == "Ada Lovelace"
      assert second.user == nil
    end

    test "breaks ties at the same timestamp by id ascending", %{card: card} do
      at = ~U[2026-07-07 12:00:00Z]
      a = insert(:comment, card: card, inserted_at: at)
      b = insert(:comment, card: card, inserted_at: at)

      assert Enum.map(Activity.list_conversation(card), & &1.id) == [a.id, b.id]
    end

    test "excludes other cards' comments", %{card: card} do
      insert(:comment, card: insert(:card))
      mine = insert(:comment, card: card)

      assert Enum.map(Activity.list_conversation(card), & &1.id) == [mine.id]
    end

    test "returns [] for a card with no comments", %{card: card} do
      insert(:activity, card: card, type: :created)
      assert Activity.list_conversation(card) == []
    end
  end

  describe "list_activity/1" do
    test "returns only activity entries, newest first, with users preloaded", %{card: card, user: user} do
      a1 = insert(:activity, card: card, type: :created, meta: %{}, inserted_at: ~U[2026-07-07 10:00:00Z])
      _c = insert(:comment, card: card, body: "hi", inserted_at: ~U[2026-07-07 10:00:10Z])
      a2 = insert(:activity, card: card, user: user, inserted_at: ~U[2026-07-07 10:00:20Z])

      activity = Activity.list_activity(card)

      assert Enum.all?(activity, &match?(%Schemas.Activity{}, &1))
      assert Enum.map(activity, & &1.id) == [a2.id, a1.id]
      assert [newest, oldest] = activity
      assert newest.user.id == user.id
      assert oldest.user == nil
    end

    test "breaks ties at the same timestamp by id descending", %{card: card} do
      at = ~U[2026-07-07 12:00:00Z]
      a = insert(:activity, card: card, inserted_at: at)
      b = insert(:activity, card: card, inserted_at: at)

      assert Enum.map(Activity.list_activity(card), & &1.id) == [b.id, a.id]
    end

    test "excludes other cards' entries", %{card: card} do
      insert(:activity, card: insert(:card))
      mine = insert(:activity, card: card)

      assert Enum.map(Activity.list_activity(card), & &1.id) == [mine.id]
    end

    test "returns [] for a card with no activity", %{card: card} do
      insert(:comment, card: card)
      assert Activity.list_activity(card) == []
    end
  end
end
