defmodule Schemas.StoryMapSchemasTest do
  use Relay.DataCase, async: true

  alias Schemas.Card
  alias Schemas.Release
  alias Schemas.StoryActivity
  alias Schemas.StoryTask

  describe "changesets" do
    test "StoryActivity requires a name and a position and never casts board_id" do
      changeset = StoryActivity.changeset(%StoryActivity{}, %{board_id: 99})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).position
      assert get_field(changeset, :board_id) == nil
    end

    test "StoryTask requires name, position and story_activity_id and never casts board_id" do
      changeset = StoryTask.changeset(%StoryTask{}, %{board_id: 99})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).position
      assert "can't be blank" in errors_on(changeset).story_activity_id
      assert get_field(changeset, :board_id) == nil
    end

    test "StoryTask casts story_activity_id so a task can move between activities" do
      changeset = StoryTask.changeset(%StoryTask{board_id: 1}, %{name: "Sign in", position: 1, story_activity_id: 7})

      assert changeset.valid?
      assert get_field(changeset, :story_activity_id) == 7
    end

    test "Release requires a name and a position and never casts board_id" do
      changeset = Release.changeset(%Release{}, %{board_id: 99})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).position
      assert get_field(changeset, :board_id) == nil
    end

    test "seed_names/0 is the one definition of the three seeded swimlanes, in order" do
      assert Release.seed_names() == ["MVP", "Fast follow", "Later"]
    end
  end

  describe "delete semantics (enforced at the database)" do
    setup do
      board = insert(:board)
      stage = insert(:stage, board: board)
      activity = insert(:story_activity, board: board)
      task = insert(:story_task, story_activity: activity)
      release = insert(:release, board: board)

      card =
        insert(:card,
          stage: stage,
          story_activity_id: activity.id,
          story_task_id: task.id,
          release_id: release.id
        )

      %{board: board, activity: activity, task: task, release: release, card: card}
    end

    test "deleting an activity deletes its tasks and unmaps the card, leaving release alone",
         %{activity: activity, task: task, release: release, card: card} do
      Repo.delete!(activity)

      reloaded = Repo.get!(Card, card.id)

      assert reloaded.title == card.title
      assert reloaded.story_activity_id == nil
      assert reloaded.story_task_id == nil
      assert reloaded.release_id == release.id
      assert Repo.get(StoryTask, task.id) == nil
    end

    test "deleting a task leaves the card in its activity's 'No task yet' column",
         %{activity: activity, task: task, release: release, card: card} do
      Repo.delete!(task)

      reloaded = Repo.get!(Card, card.id)

      assert reloaded.story_task_id == nil
      assert reloaded.story_activity_id == activity.id
      assert reloaded.release_id == release.id
    end

    test "deleting a release only nilifies release_id",
         %{activity: activity, task: task, release: release, card: card} do
      Repo.delete!(release)

      reloaded = Repo.get!(Card, card.id)

      assert reloaded.release_id == nil
      assert reloaded.story_activity_id == activity.id
      assert reloaded.story_task_id == task.id
    end
  end
end
