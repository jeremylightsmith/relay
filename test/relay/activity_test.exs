defmodule Relay.ActivityTest do
  use Relay.DataCase, async: true

  alias Relay.Activity
  alias Schemas.Attachment
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

    test "defaults kind to :comment and accepts an explicit kind", %{card: card} do
      assert {:ok, plain} = Activity.add_comment(card, %{actor: :agent, body: "hi"})
      assert plain.kind == :comment

      assert {:ok, tagged} =
               Activity.add_comment(card, %{actor: :agent, body: "q?", kind: :question})

      assert tagged.kind == :question
    end
  end

  describe "add_comment/2 with image_ids (RE427)" do
    setup %{card: card} do
      a = insert(:attachment, card: card, filename: "a.png")
      b = insert(:attachment, card: card, filename: "b.png")
      %{a: a, b: b}
    end

    test "links the images to the note in the given order with positions", %{card: card, user: user, a: a, b: b} do
      assert {:ok, %Comment{} = comment} =
               Activity.add_comment(card, %{actor: {:user, user.id}, body: "see screenshots", image_ids: [a.id, b.id]})

      assert comment.body == "see screenshots"
      assert Enum.map(comment.images, & &1.id) == [a.id, b.id]

      assert %Attachment{comment_id: comment_id, position: 0} = Repo.get!(Attachment, a.id)
      assert comment_id == comment.id
      assert %Attachment{comment_id: ^comment_id, position: 1} = Repo.get!(Attachment, b.id)
    end

    test "orders images by the given list, not insert time", %{card: card, user: user, a: a, b: b} do
      assert {:ok, comment} =
               Activity.add_comment(card, %{actor: {:user, user.id}, body: "reversed", image_ids: [b.id, a.id]})

      assert Enum.map(comment.images, & &1.id) == [b.id, a.id]
    end

    test "allows an image-only note with a blank body", %{card: card, user: user, a: a} do
      assert {:ok, comment} = Activity.add_comment(card, %{actor: {:user, user.id}, body: "", image_ids: [a.id]})

      assert comment.body in [nil, ""]
      assert Enum.map(comment.images, & &1.id) == [a.id]
    end

    test "rejects more than max_images and changes nothing", %{card: card, user: user, a: a, b: b} do
      extra = for _ <- 1..(Comment.max_images() + 1 - 2), do: insert(:attachment, card: card)
      ids = [a.id, b.id | Enum.map(extra, & &1.id)]
      assert length(ids) == 7

      assert {:error, changeset} = Activity.add_comment(card, %{actor: {:user, user.id}, body: "many", image_ids: ids})

      assert "can carry at most 6 images" in errors_on(changeset).images
      assert Repo.aggregate(Comment, :count) == 0
      assert Enum.all?(ids, &is_nil(Repo.get!(Attachment, &1).comment_id))
    end

    test "rejects an image on another card", %{card: card, user: user} do
      foreign = insert(:attachment, card: insert(:card))

      assert {:error, changeset} =
               Activity.add_comment(card, %{actor: {:user, user.id}, body: "x", image_ids: [foreign.id]})

      assert "must be images uploaded to this card" in errors_on(changeset).images
      assert Repo.aggregate(Comment, :count) == 0
      assert is_nil(Repo.get!(Attachment, foreign.id).comment_id)
    end

    test "rejects a non-image attachment on the same card", %{card: card, user: user} do
      html = insert(:attachment, card: card, filename: "m.html", content_type: Attachment.html_type())

      assert {:error, changeset} = Activity.add_comment(card, %{actor: {:user, user.id}, body: "x", image_ids: [html.id]})

      assert "must be images uploaded to this card" in errors_on(changeset).images
      assert Repo.aggregate(Comment, :count) == 0
    end

    test "rejects an image already linked to an earlier comment", %{card: card, user: user, a: a} do
      {:ok, earlier} = Activity.add_comment(card, %{actor: {:user, user.id}, body: "first", image_ids: [a.id]})

      assert {:error, changeset} =
               Activity.add_comment(card, %{actor: {:user, user.id}, body: "again", image_ids: [a.id]})

      assert "must be images uploaded to this card" in errors_on(changeset).images
      assert Repo.get!(Attachment, a.id).comment_id == earlier.id
      assert Repo.aggregate(Comment, :count) == 1
    end

    test "rejects a non-UUID id without raising", %{card: card, user: user} do
      assert {:error, changeset} =
               Activity.add_comment(card, %{actor: {:user, user.id}, body: "x", image_ids: ["not-a-uuid"]})

      assert "must be images uploaded to this card" in errors_on(changeset).images
      assert Repo.aggregate(Comment, :count) == 0
    end

    test "broadcasts the comment with its images preloaded", %{card: card, user: user, a: a} do
      Relay.Events.subscribe(card.board_id)
      card_id = card.id
      a_id = a.id

      {:ok, _comment} = Activity.add_comment(card, %{actor: {:user, user.id}, body: "pic", image_ids: [a_id]})

      assert_receive {:timeline_appended, ^card_id, %Comment{images: [%Attachment{id: ^a_id}]}}
    end

    test "a comment posted without image_ids has images preloaded as []", %{card: card} do
      assert {:ok, comment} = Activity.add_comment(card, %{actor: :agent, body: "no pics"})
      assert comment.images == []
    end

    test "list_conversation/1 and list_timeline/1 preload images in position order", %{
      card: card,
      user: user,
      a: a,
      b: b
    } do
      {:ok, with_images} = Activity.add_comment(card, %{actor: {:user, user.id}, body: "pics", image_ids: [a.id, b.id]})
      {:ok, plain} = Activity.add_comment(card, %{actor: :agent, body: "plain"})

      for list <- [Activity.list_conversation(card), Activity.list_timeline(card)] do
        comments = Enum.filter(list, &match?(%Comment{}, &1))
        assert Enum.map(Enum.find(comments, &(&1.id == with_images.id)).images, & &1.id) == [a.id, b.id]
        assert Enum.find(comments, &(&1.id == plain.id)).images == []
      end
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
