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
      assert Cards.ref(%Board{key: "RLY"}, %Card{ref_number: 12}) == "RLY12"
      assert Cards.format_ref("RL", 230) == "RL230"
    end
  end

  describe "status and progress" do
    test "a new card defaults to :ready" do
      card = insert(:card)

      reloaded = Repo.get!(Card, card.id)
      assert reloaded.status == :ready
    end

    test "changeset/2 does not cast status" do
      changeset = Card.changeset(%Card{}, %{title: "T", status: "in_review"})

      assert get_field(changeset, :status) == :ready
    end

    test "status enum includes :queued (RLY-133), defaulting to :ready" do
      assert %Card{}.status == :ready

      ok = Card.status_changeset(%Card{}, %{status: :in_review})
      assert ok.valid?

      queued = Card.status_changeset(%Card{}, %{status: :queued})
      assert queued.valid?

      bad = Card.status_changeset(%Card{}, %{status: :bogus})
      refute bad.valid?
      assert %{status: ["is invalid"]} = errors_on(bad)
    end

    test "entering :ready clears blocked_since" do
      blocked = %Card{status: :needs_input, blocked_since: ~U[2026-07-01 00:00:00Z]}
      changeset = Card.status_changeset(blocked, %{status: :ready})
      assert Ecto.Changeset.get_change(changeset, :blocked_since) == nil
    end
  end

  describe "status_changeset/2" do
    test "casts status only" do
      changeset = Card.status_changeset(%Card{}, %{status: "working"})

      assert changeset.valid?
      assert get_field(changeset, :status) == :working
    end

    test "rejects an unknown status" do
      changeset = Card.status_changeset(%Card{}, %{status: "sleeping"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "ignores a progress key (progress is no longer stored)" do
      changeset = Card.status_changeset(%Card{}, %{status: "working", progress: 40})

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :progress)
    end
  end

  describe "archived?/1" do
    test "false when archived_at is nil" do
      refute Card.archived?(%Card{archived_at: nil})
    end

    test "true when archived_at is set" do
      assert Card.archived?(%Card{archived_at: DateTime.utc_now()})
    end

    test "archived_at is never cast from user input" do
      changeset =
        Card.changeset(%Card{}, %{title: "T", archived_at: DateTime.utc_now()})

      assert get_field(changeset, :archived_at) == nil
    end
  end
end
