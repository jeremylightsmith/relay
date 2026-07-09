defmodule Schemas.CardRejectionTest do
  use Relay.DataCase, async: true

  alias Schemas.Card
  alias Schemas.CardRejection

  describe "changeset/2" do
    test "requires a note" do
      changeset = CardRejection.changeset(%CardRejection{}, %{from_stage_name: "Review"})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).note
    end

    test "casts all snapshot fields" do
      attrs = %{
        note: "Redo the spec",
        from_stage_id: 5,
        from_stage_name: "Review",
        to_stage_id: 2,
        to_stage_name: "Spec",
        rejected_by: "Jeremy",
        rejected_at: ~U[2026-07-08 12:00:00Z]
      }

      changeset = CardRejection.changeset(%CardRejection{}, attrs)

      assert changeset.valid?
      assert get_field(changeset, :note) == "Redo the spec"
      assert get_field(changeset, :from_stage_name) == "Review"
      assert get_field(changeset, :to_stage_id) == 2
    end
  end

  describe "Card embed" do
    test "a fresh card has no open rejection" do
      card = insert(:card)
      assert Repo.get!(Card, card.id).rejection == nil
    end

    test "does not cast :rejection from user input" do
      changeset = Card.changeset(%Card{}, %{title: "T", rejection: %{note: "sneaky"}})
      assert get_field(changeset, :rejection) == nil
    end
  end
end
