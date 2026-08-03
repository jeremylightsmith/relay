defmodule Schemas.CardStoryMapChangesetTest do
  use Relay.DataCase, async: true

  alias Schemas.Card

  test "casts the three story-map columns" do
    changeset = Card.story_map_changeset(%Card{}, %{story_activity_id: 1, story_task_id: 2, release_id: 3})

    assert changeset.valid?
    assert get_field(changeset, :story_activity_id) == 1
    assert get_field(changeset, :story_task_id) == 2
    assert get_field(changeset, :release_id) == 3
  end

  test "all three are optional — a fully unmapped card is valid" do
    changeset = Card.story_map_changeset(%Card{}, %{})

    assert changeset.valid?
    assert get_field(changeset, :story_activity_id) == nil
    assert get_field(changeset, :story_task_id) == nil
    assert get_field(changeset, :release_id) == nil
  end

  test "an activity with no task is valid — the 'No task yet' state" do
    changeset = Card.story_map_changeset(%Card{}, %{story_activity_id: 1})

    assert changeset.valid?
    assert get_field(changeset, :story_task_id) == nil
  end

  test "a release with no activity or task is valid — release is independent" do
    changeset = Card.story_map_changeset(%Card{}, %{release_id: 3})

    assert changeset.valid?
  end

  test "rejects a task without an activity — the half-state can never be persisted" do
    changeset = Card.story_map_changeset(%Card{}, %{story_task_id: 2})

    refute changeset.valid?
    assert "is required when a story task is set" in errors_on(changeset).story_activity_id
  end

  test "rejects clearing the activity while a task stays set" do
    card = %Card{story_activity_id: 1, story_task_id: 2}
    changeset = Card.story_map_changeset(card, %{story_activity_id: nil})

    refute changeset.valid?
    assert "is required when a story task is set" in errors_on(changeset).story_activity_id
  end

  test "does not touch title, status or any other card field" do
    card = %Card{title: "Keep me", status: :ready}
    changeset = Card.story_map_changeset(card, %{title: "Changed", status: :working, release_id: 3})

    assert get_field(changeset, :title) == "Keep me"
    assert get_field(changeset, :status) == :ready
    assert get_field(changeset, :release_id) == 3
  end
end
