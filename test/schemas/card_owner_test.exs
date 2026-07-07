defmodule Schemas.CardOwnerTest do
  use Relay.DataCase, async: true

  alias Schemas.Card
  alias Schemas.CardOwner

  describe "changeset/1" do
    test "is valid for an agent owner (no user_id)" do
      card = insert(:card)

      changeset = CardOwner.changeset(%CardOwner{card_id: card.id, actor_type: :agent})

      assert changeset.valid?
    end

    test "is valid for a user owner with a user_id" do
      card = insert(:card)
      user = insert(:user)

      changeset =
        CardOwner.changeset(%CardOwner{card_id: card.id, actor_type: :user, user_id: user.id})

      assert changeset.valid?
    end

    test "requires card_id and actor_type" do
      changeset = CardOwner.changeset(%CardOwner{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).card_id
      assert "can't be blank" in errors_on(changeset).actor_type
    end

    test "a user owner requires a user_id" do
      card = insert(:card)

      changeset = CardOwner.changeset(%CardOwner{card_id: card.id, actor_type: :user})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).user_id
    end

    test "an agent owner must not carry a user_id" do
      card = insert(:card)
      user = insert(:user)

      changeset =
        CardOwner.changeset(%CardOwner{card_id: card.id, actor_type: :agent, user_id: user.id})

      refute changeset.valid?
      assert "must be empty for the AI agent" in errors_on(changeset).user_id
    end
  end

  describe "persistence" do
    test "rejects a duplicate user owner on the same card" do
      card = insert(:card)
      user = insert(:user)
      owner = %CardOwner{card_id: card.id, actor_type: :user, user_id: user.id}

      assert {:ok, _} = Repo.insert(CardOwner.changeset(owner))
      assert {:error, changeset} = Repo.insert(CardOwner.changeset(owner))
      refute changeset.valid?
    end

    test "rejects a duplicate agent owner on the same card" do
      card = insert(:card)
      owner = %CardOwner{card_id: card.id, actor_type: :agent}

      assert {:ok, _} = Repo.insert(CardOwner.changeset(owner))
      assert {:error, changeset} = Repo.insert(CardOwner.changeset(owner))
      refute changeset.valid?
    end

    test "rejects an unknown user_id with a changeset error" do
      card = insert(:card)

      assert {:error, changeset} =
               Repo.insert(CardOwner.changeset(%CardOwner{card_id: card.id, actor_type: :user, user_id: -1}))

      refute changeset.valid?
    end

    test "insert(:card_owner) builds an agent owner; passing user builds a human owner" do
      agent_owner = insert(:card_owner)
      user = insert(:user)
      card = insert(:card)
      human_owner = insert(:card_owner, card: card, user: user)

      assert agent_owner.actor_type == :agent
      assert agent_owner.user_id == nil
      assert human_owner.actor_type == :user
      assert human_owner.user_id == user.id
      assert human_owner.card_id == card.id
    end

    test "deleting a card deletes its owner rows" do
      card = insert(:card)
      owner = insert(:card_owner, card: card)

      Repo.delete!(Repo.get!(Card, card.id))

      assert Repo.get(CardOwner, owner.id) == nil
    end

    test "a card preloads its owners" do
      card = insert(:card)
      insert(:card_owner, card: card)

      assert [%CardOwner{actor_type: :agent}] =
               Repo.preload(Repo.get!(Card, card.id), :owners).owners
    end
  end
end
