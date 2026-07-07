defmodule Relay.Cards.CardTest do
  use Relay.DataCase, async: true

  alias Relay.Boards.Board
  alias Relay.Boards.Stage
  alias Relay.Cards
  alias Relay.Cards.Card

  describe "changeset/2" do
    test "requires a title" do
      changeset = Card.changeset(%Card{}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).title
    end

    test "casts title and tag" do
      changeset = Card.changeset(%Card{}, %{title: "Ship it", tag: "infra"})

      assert changeset.valid?
      assert get_field(changeset, :title) == "Ship it"
      assert get_field(changeset, :tag) == "infra"
    end

    test "does not cast programmatically-set fields" do
      changeset = Card.changeset(%Card{}, %{board_id: 99, stage_id: 99, position: 5, ref_number: 7})

      assert get_field(changeset, :board_id) == nil
      assert get_field(changeset, :stage_id) == nil
      assert get_field(changeset, :position) == nil
      assert get_field(changeset, :ref_number) == nil
    end
  end

  describe "persistence" do
    test "insert(:card) persists a card whose stage belongs to the card's board" do
      card = insert(:card)

      assert card.id
      stage = Repo.get!(Stage, card.stage_id)
      assert stage.board_id == card.board_id
    end

    test "boards start with card_seq 0" do
      board = insert(:board)

      assert Repo.get!(Board, board.id).card_seq == 0
    end
  end

  describe "Cards.ref/2" do
    test "formats the human-facing ref from the board key and ref_number" do
      assert Cards.ref(%Board{key: "RLY"}, %Card{ref_number: 12}) == "RLY-12"
    end
  end
end
