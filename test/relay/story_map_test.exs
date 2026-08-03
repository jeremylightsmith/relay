defmodule Relay.StoryMapTest do
  use Relay.DataCase, async: true

  alias Relay.Cards
  alias Relay.Events
  alias Relay.StoryMap
  alias Schemas.Card
  alias Schemas.Release
  alias Schemas.StoryActivity
  alias Schemas.StoryTask

  setup do
    board = insert(:board)
    stage = insert(:stage, board: board)
    %{board: board, stage: stage}
  end

  describe "reads are board-scoped and position-ordered" do
    test "list_activities/1 returns only this board's activities in position order", %{board: board} do
      other = insert(:board)
      second = insert(:story_activity, board: board, name: "Second", position: 2)
      first = insert(:story_activity, board: board, name: "First", position: 1)
      insert(:story_activity, board: other, name: "Elsewhere", position: 1)

      assert Enum.map(StoryMap.list_activities(board), & &1.id) == [first.id, second.id]
    end

    test "list_activities/1 accepts a board id as well as a board", %{board: board} do
      activity = insert(:story_activity, board: board)

      assert Enum.map(StoryMap.list_activities(board.id), & &1.id) == [activity.id]
    end

    test "list_tasks/1 returns the board's tasks ordered by (activity, position)", %{board: board} do
      a1 = insert(:story_activity, board: board, position: 1)
      a2 = insert(:story_activity, board: board, position: 2)
      t2 = insert(:story_task, story_activity: a1, position: 2)
      t1 = insert(:story_task, story_activity: a1, position: 1)
      t3 = insert(:story_task, story_activity: a2, position: 1)
      insert(:story_task, story_activity: insert(:story_activity, board: insert(:board)))

      assert Enum.map(StoryMap.list_tasks(board), & &1.id) == [t1.id, t2.id, t3.id]
    end

    test "list_releases/1 returns only this board's releases in position order", %{board: board} do
      later = insert(:release, board: board, name: "Later", position: 3)
      mvp = insert(:release, board: board, name: "MVP", position: 1)
      insert(:release, board: insert(:board), name: "Elsewhere", position: 1)

      assert Enum.map(StoryMap.list_releases(board), & &1.name) == [mvp.name, later.name]
    end
  end

  describe "next_position/1 — the one definition of goes at the end" do
    test "an empty list starts at 1" do
      assert StoryMap.next_position([]) == 1
    end

    test "a list appends one past its highest position, sparse or out of order" do
      assert StoryMap.next_position([%{position: 1}, %{position: 2}]) == 3
      assert StoryMap.next_position([%{position: 7}, %{position: 2}]) == 8
      assert StoryMap.next_position([%{position: 3}, %{position: 40}, %{position: 12}]) == 41
    end

    test "it composes with the board-scoped reads it is called with", %{board: board} do
      insert(:story_activity, board: board, position: 4)
      insert(:story_activity, board: insert(:board), position: 99)

      assert StoryMap.next_position(StoryMap.list_activities(board)) == 5
    end
  end

  describe "structure writes" do
    test "create_activity/2 sets board_id from the board and never from input", %{board: board} do
      other = insert(:board)

      {:ok, activity} = StoryMap.create_activity(board, %{name: "Onboard", position: 1, board_id: other.id})

      assert activity.board_id == board.id
      assert activity.name == "Onboard"
    end

    test "create_activity/2 returns an error changeset for a blank name", %{board: board} do
      assert {:error, changeset} = StoryMap.create_activity(board, %{name: "", position: 1})
      assert "can't be blank" in errors_on(changeset).name
    end

    test "update_activity/2 renames", %{board: board} do
      activity = insert(:story_activity, board: board, name: "Old")

      {:ok, updated} = StoryMap.update_activity(activity, %{name: "New"})

      assert updated.name == "New"
    end

    test "delete_activity/1 removes it", %{board: board} do
      activity = insert(:story_activity, board: board)

      assert {:ok, _} = StoryMap.delete_activity(activity)
      assert Repo.get(StoryActivity, activity.id) == nil
    end

    test "reorder_activities/2 rewrites positions to 1..n and ignores foreign ids", %{board: board} do
      a = insert(:story_activity, board: board, position: 1)
      b = insert(:story_activity, board: board, position: 2)
      foreign = insert(:story_activity, board: insert(:board), position: 9)

      assert :ok = StoryMap.reorder_activities(board, [b.id, a.id, foreign.id])

      assert Enum.map(StoryMap.list_activities(board), & &1.id) == [b.id, a.id]
      assert Repo.get!(StoryActivity, foreign.id).position == 9
    end

    test "create_task/2 takes board_id from the parent activity", %{board: board} do
      activity = insert(:story_activity, board: board)

      {:ok, task} = StoryMap.create_task(activity, %{name: "Sign in", position: 1})

      assert task.board_id == board.id
      assert task.story_activity_id == activity.id
    end

    test "create_task/2 accepts an activity id", %{board: board} do
      activity = insert(:story_activity, board: board)

      {:ok, task} = StoryMap.create_task(activity.id, %{name: "Sign in", position: 1})

      assert task.board_id == board.id
      assert task.story_activity_id == activity.id
    end

    test "update_task/2 moves a task to another activity on the same board", %{board: board} do
      a1 = insert(:story_activity, board: board)
      a2 = insert(:story_activity, board: board)
      task = insert(:story_task, story_activity: a1)

      {:ok, moved} = StoryMap.update_task(task, %{story_activity_id: a2.id})

      assert moved.story_activity_id == a2.id
    end

    test "update_task/2 drags mapped cards' story_activity_id along with the task", %{board: board, stage: stage} do
      a1 = insert(:story_activity, board: board)
      a2 = insert(:story_activity, board: board)
      task = insert(:story_task, story_activity: a1)
      card = insert(:card, board: board, stage: stage)
      {:ok, card} = StoryMap.assign_card(card, %{story_task_id: task.id})
      assert card.story_activity_id == a1.id

      Events.subscribe(board.id)
      {:ok, _moved} = StoryMap.update_task(task, %{story_activity_id: a2.id})

      assert Repo.get!(Card, card.id).story_activity_id == a2.id
      assert_receive {:card_upserted, %Card{id: id, story_activity_id: activity_id}}
      assert id == card.id
      assert activity_id == a2.id
    end

    test "update_task/2 leaves cards mapped to other tasks alone", %{board: board, stage: stage} do
      a1 = insert(:story_activity, board: board)
      a2 = insert(:story_activity, board: board)
      task = insert(:story_task, story_activity: a1)
      other_task = insert(:story_task, story_activity: a1)
      other_card = insert(:card, board: board, stage: stage)
      {:ok, other_card} = StoryMap.assign_card(other_card, %{story_task_id: other_task.id})

      {:ok, _moved} = StoryMap.update_task(task, %{story_activity_id: a2.id})

      assert Repo.get!(Card, other_card.id).story_activity_id == a1.id
    end

    test "update_task/2 rejects a move to another board's activity", %{board: board} do
      task = insert(:story_task, story_activity: insert(:story_activity, board: board))
      foreign = insert(:story_activity, board: insert(:board))

      assert {:error, changeset} = StoryMap.update_task(task, %{story_activity_id: foreign.id})
      assert "must belong to the same board" in errors_on(changeset).story_activity_id
      assert Repo.get!(StoryTask, task.id).story_activity_id == task.story_activity_id
    end

    test "delete_task/1 removes it", %{board: board} do
      task = insert(:story_task, story_activity: insert(:story_activity, board: board))

      assert {:ok, _} = StoryMap.delete_task(task)
      assert Repo.get(StoryTask, task.id) == nil
    end

    test "reorder_tasks/2 rewrites positions to 1..n", %{board: board} do
      activity = insert(:story_activity, board: board)
      a = insert(:story_task, story_activity: activity, position: 1)
      b = insert(:story_task, story_activity: activity, position: 2)

      assert :ok = StoryMap.reorder_tasks(board, [b.id, a.id])

      assert Repo.get!(StoryTask, b.id).position == 1
      assert Repo.get!(StoryTask, a.id).position == 2
    end

    test "create/update/delete/reorder releases", %{board: board} do
      {:ok, release} = StoryMap.create_release(board, %{name: "Beta", position: 4})
      assert release.board_id == board.id

      {:ok, renamed} = StoryMap.update_release(release, %{name: "Beta 2"})
      assert renamed.name == "Beta 2"

      other = insert(:release, board: board, position: 5)
      assert :ok = StoryMap.reorder_releases(board, [other.id, renamed.id])
      assert Repo.get!(Release, other.id).position == 1
      assert Repo.get!(Release, renamed.id).position == 2

      assert {:ok, _} = StoryMap.delete_release(renamed)
      assert Repo.get(Release, renamed.id) == nil
    end
  end

  describe "assign_card/2" do
    setup %{board: board, stage: stage} do
      activity = insert(:story_activity, board: board)
      task = insert(:story_task, story_activity: activity)
      release = insert(:release, board: board)
      card = insert(:card, stage: stage)

      %{activity: activity, task: task, release: release, card: card}
    end

    test "sets all three columns", %{card: card, activity: activity, task: task, release: release} do
      {:ok, assigned} =
        StoryMap.assign_card(card, %{
          story_activity_id: activity.id,
          story_task_id: task.id,
          release_id: release.id
        })

      assert assigned.story_activity_id == activity.id
      assert assigned.story_task_id == task.id
      assert assigned.release_id == release.id
    end

    test "derives the activity from the task, ignoring a conflicting one", %{
      card: card,
      task: task,
      activity: activity,
      board: board
    } do
      conflicting = insert(:story_activity, board: board)

      {:ok, assigned} =
        StoryMap.assign_card(card, %{story_task_id: task.id, story_activity_id: conflicting.id})

      assert assigned.story_activity_id == activity.id
      assert assigned.story_task_id == task.id
    end

    test "a task alone is enough — the activity comes from it", %{card: card, task: task, activity: activity} do
      {:ok, assigned} = StoryMap.assign_card(card, %{story_task_id: task.id})

      assert assigned.story_activity_id == activity.id
    end

    test "an activity with no task is the 'No task yet' state", %{card: card, activity: activity} do
      {:ok, assigned} = StoryMap.assign_card(card, %{story_activity_id: activity.id})

      assert assigned.story_activity_id == activity.id
      assert assigned.story_task_id == nil
    end

    test "a mapped card may have no release", %{card: card, task: task} do
      {:ok, assigned} = StoryMap.assign_card(card, %{story_task_id: task.id})

      assert assigned.release_id == nil
    end

    test "omitted columns are cleared — assign_card/2 sets the whole placement", %{
      card: card,
      task: task,
      release: release,
      activity: activity
    } do
      {:ok, mapped} =
        StoryMap.assign_card(card, %{story_task_id: task.id, release_id: release.id})

      assert mapped.release_id == release.id

      {:ok, remapped} = StoryMap.assign_card(mapped, %{story_activity_id: activity.id})

      assert remapped.story_activity_id == activity.id
      assert remapped.story_task_id == nil
      assert remapped.release_id == nil
    end

    test "rejects an activity from another board", %{card: card} do
      foreign = insert(:story_activity, board: insert(:board))

      assert {:error, changeset} = StoryMap.assign_card(card, %{story_activity_id: foreign.id})
      assert "does not belong to this card's board" in errors_on(changeset).story_activity_id
    end

    test "rejects a task from another board", %{card: card} do
      foreign = insert(:story_task, story_activity: insert(:story_activity, board: insert(:board)))

      assert {:error, changeset} = StoryMap.assign_card(card, %{story_task_id: foreign.id})
      assert "does not belong to this card's board" in errors_on(changeset).story_task_id
    end

    test "rejects a release from another board", %{card: card} do
      foreign = insert(:release, board: insert(:board))

      assert {:error, changeset} = StoryMap.assign_card(card, %{release_id: foreign.id})
      assert "does not belong to this card's board" in errors_on(changeset).release_id
    end
  end

  describe "unassign_card/1" do
    test "clears all three columns", %{board: board, stage: stage} do
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

      {:ok, cleared} = StoryMap.unassign_card(card)

      assert cleared.story_activity_id == nil
      assert cleared.story_task_id == nil
      assert cleared.release_id == nil
    end
  end

  describe "realtime" do
    setup %{board: board} do
      :ok = Events.subscribe(board.id)
      :ok
    end

    test "a structure write broadcasts {:story_map_changed, board_id}", %{board: board} do
      board_id = board.id

      {:ok, activity} = StoryMap.create_activity(board, %{name: "Onboard", position: 1})
      assert_receive {:story_map_changed, ^board_id}

      {:ok, _} = StoryMap.update_activity(activity, %{name: "Onboarding"})
      assert_receive {:story_map_changed, ^board_id}

      {:ok, task} = StoryMap.create_task(activity, %{name: "Sign in", position: 1})
      assert_receive {:story_map_changed, ^board_id}

      :ok = StoryMap.reorder_tasks(board, [task.id])
      assert_receive {:story_map_changed, ^board_id}

      {:ok, _} = StoryMap.delete_activity(activity)
      assert_receive {:story_map_changed, ^board_id}
    end

    test "a failed structure write broadcasts nothing", %{board: board} do
      {:error, _changeset} = StoryMap.create_activity(board, %{name: "", position: 1})

      refute_receive {:story_map_changed, _board_id}, 100
    end

    test "assign_card/2 broadcasts {:card_upserted, card} with owners preloaded",
         %{board: board, stage: stage} do
      activity = insert(:story_activity, board: board)
      {:ok, card} = Cards.create_card(stage, %{title: "Mapped"})
      card_id = card.id
      activity_id = activity.id

      {:ok, _} = StoryMap.assign_card(card, %{story_activity_id: activity.id})

      assert_receive {:card_upserted, %Card{id: ^card_id, story_activity_id: ^activity_id, owners: owners}}
                     when is_list(owners)
    end

    test "unassign_card/1 broadcasts {:card_upserted, card}", %{board: board, stage: stage} do
      activity = insert(:story_activity, board: board)
      card = insert(:card, stage: stage, story_activity_id: activity.id)
      card_id = card.id

      {:ok, _} = StoryMap.unassign_card(card)

      assert_receive {:card_upserted, %Card{id: ^card_id, story_activity_id: nil}}
    end
  end
end
