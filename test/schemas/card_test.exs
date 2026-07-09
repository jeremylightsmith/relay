defmodule Schemas.CardTest do
  use Relay.DataCase, async: true

  alias Relay.Cards
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Stage

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

    test "casts spec and treats it as optional (nullable)" do
      changeset = Card.changeset(%Card{}, %{title: "T", spec: "## Design\n\nDetails"})

      assert changeset.valid?
      assert get_field(changeset, :spec) == "## Design\n\nDetails"

      without = Card.changeset(%Card{}, %{title: "T"})
      assert without.valid?
      assert get_field(without, :spec) == nil
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

  describe "status and progress" do
    test "a new card defaults to :queued with nil progress" do
      card = insert(:card)

      reloaded = Repo.get!(Card, card.id)
      assert reloaded.status == :queued
      assert reloaded.progress == nil
    end

    test "changeset/2 does not cast status or progress" do
      changeset = Card.changeset(%Card{}, %{title: "T", status: "done", progress: 90})

      assert get_field(changeset, :status) == :queued
      assert get_field(changeset, :progress) == nil
    end
  end

  describe "status_changeset/2" do
    test "casts status and progress" do
      changeset = Card.status_changeset(%Card{}, %{status: "working", progress: 40})

      assert changeset.valid?
      assert get_field(changeset, :status) == :working
      assert get_field(changeset, :progress) == 40
    end

    test "rejects an unknown status" do
      changeset = Card.status_changeset(%Card{}, %{status: "sleeping"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "rejects progress outside 0..100" do
      for bad <- [-1, 101] do
        changeset = Card.status_changeset(%Card{}, %{status: "working", progress: bad})

        refute changeset.valid?
        assert Map.has_key?(errors_on(changeset), :progress)
      end
    end

    test "allows nil progress" do
      changeset = Card.status_changeset(%Card{}, %{status: "working"})

      assert changeset.valid?
    end
  end
end
