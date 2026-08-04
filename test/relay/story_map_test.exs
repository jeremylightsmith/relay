defmodule Relay.StoryMapTest do
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Events
  alias Relay.StoryMap
  alias Schemas.Board
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

    test "an over-long name is an error changeset, not a Postgres crash", %{board: board} do
      # All three `name` columns are varchar(255); without a length validation `Repo.insert/1`
      # raises Postgrex 22001 instead of returning `{:error, changeset}`, and RE263 is the
      # first path that lets an end user supply these names.
      long = String.duplicate("a", 81)

      assert {:error, activity_cs} = StoryMap.create_activity(board, %{name: long, position: 1})
      assert "should be at most 80 character(s)" in errors_on(activity_cs).name

      activity = insert(:story_activity, board: board)
      assert {:error, task_cs} = StoryMap.create_task(activity, %{name: long, position: 1})
      assert "should be at most 80 character(s)" in errors_on(task_cs).name

      assert {:error, release_cs} = StoryMap.create_release(board, %{name: long, position: 1})
      assert "should be at most 80 character(s)" in errors_on(release_cs).name
    end

    test "a padded name is trimmed by the schema, not by the caller", %{board: board} do
      # `Schemas.Board` pairs its name length cap with `update_change(:name, &String.trim/1)`;
      # these three did not, so " Foo " stored its padding and every future write path
      # (RE261's rename) would have to re-trim in the web layer to stay correct.
      assert {:ok, activity} = StoryMap.create_activity(board, %{name: "  Onboard  ", position: 1})
      assert activity.name == "Onboard"

      assert {:ok, task} = StoryMap.create_task(activity, %{name: "  Sign in  ", position: 1})
      assert task.name == "Sign in"

      assert {:ok, release} = StoryMap.create_release(board, %{name: "  MVP 2  ", position: 9})
      assert release.name == "MVP 2"
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

  describe "insert_before/3 — the one ordering rule" do
    test "inserts the dragged id immediately before the target" do
      assert StoryMap.insert_before([1, 2, 3], 3, 1) == [3, 1, 2]
      assert StoryMap.insert_before([1, 2, 3], 1, 3) == [2, 1, 3]
      assert StoryMap.insert_before([1, 2, 3], 1, 2) == [1, 2, 3]
    end

    test "dropping something on itself is the identity" do
      assert StoryMap.insert_before([1, 2, 3], 2, 2) == [1, 2, 3]
    end

    test "a target that is not in the list appends" do
      assert StoryMap.insert_before([1, 2, 3], 1, 99) == [2, 3, 1]
      assert StoryMap.insert_before([], 1, 99) == [1]
    end

    test "an id that is not in the list is inserted rather than lost" do
      assert StoryMap.insert_before([1, 2], 9, 2) == [1, 9, 2]
    end
  end

  describe "deleting a structure that still holds cards" do
    setup %{board: board, stage: stage} do
      activity = insert(:story_activity, board: board)
      task = insert(:story_task, story_activity: activity)
      release = insert(:release, board: board)
      card = insert(:card, board: board, stage: stage)
      {:ok, card} = StoryMap.assign_card(card, %{story_task_id: task.id, release_id: release.id})

      %{activity: activity, task: task, release: release, card: card}
    end

    test "delete_activity/1 refuses while a card points at it, and succeeds once it does not",
         ctx do
      assert {:error, :not_empty} = StoryMap.delete_activity(ctx.activity)
      assert Repo.get(StoryActivity, ctx.activity.id)

      {:ok, _unmapped} = StoryMap.unassign_card(ctx.card)

      assert {:ok, _deleted} = StoryMap.delete_activity(ctx.activity)
      assert Repo.get(StoryActivity, ctx.activity.id) == nil
    end

    test "delete_task/1 refuses while a card points at it, and succeeds once it does not", ctx do
      assert {:error, :not_empty} = StoryMap.delete_task(ctx.task)
      assert Repo.get(StoryTask, ctx.task.id)

      {:ok, _unmapped} = StoryMap.unassign_card(ctx.card)

      assert {:ok, _deleted} = StoryMap.delete_task(ctx.task)
      assert Repo.get(StoryTask, ctx.task.id) == nil
    end

    test "delete_release/1 refuses while a card points at it, and succeeds once it does not",
         ctx do
      assert {:error, :not_empty} = StoryMap.delete_release(ctx.release)
      assert Repo.get(Release, ctx.release.id)

      {:ok, _cleared} = StoryMap.assign_card(ctx.card, %{story_task_id: ctx.task.id})

      assert {:ok, _deleted} = StoryMap.delete_release(ctx.release)
      assert Repo.get(Release, ctx.release.id) == nil
    end

    # `Cards.list_cards/1` never shows archived cards, so the grid counts 0 and renders an
    # ENABLED ✕. Without the `is_nil(archived_at)` filter the server would then refuse it — a
    # dead button.
    test "a structure holding only ARCHIVED cards deletes fine", %{board: board, stage: stage} do
      activity = insert(:story_activity, board: board)
      task = insert(:story_task, story_activity: activity)
      release = insert(:release, board: board)
      card = insert(:card, board: board, stage: stage)
      {:ok, card} = StoryMap.assign_card(card, %{story_task_id: task.id, release_id: release.id})
      {:ok, _archived} = Cards.archive_card(card)

      assert {:ok, _} = StoryMap.delete_task(task)
      assert {:ok, _} = StoryMap.delete_activity(activity)
      assert {:ok, _} = StoryMap.delete_release(release)
    end

    test "a refused delete broadcasts nothing", %{board: board} = ctx do
      Events.subscribe(board.id)

      assert {:error, :not_empty} = StoryMap.delete_activity(ctx.activity)

      refute_receive {:story_map_changed, _board_id}
    end

    test "a structure on another board's card does not block this board's delete",
         %{board: board} do
      # The count is board-scoped as well as id-scoped: two boards can hold the same id space
      # only by coincidence, but the `where` proves the scoping is not accidental.
      activity = insert(:story_activity, board: board)
      other_board = insert(:board)
      other_stage = insert(:stage, board: other_board)
      other_activity = insert(:story_activity, board: other_board)
      other_card = insert(:card, board: other_board, stage: other_stage)
      {:ok, _} = StoryMap.assign_card(other_card, %{story_activity_id: other_activity.id})

      assert {:ok, _deleted} = StoryMap.delete_activity(activity)
    end
  end

  describe "move_task/3 — the single task-repositioning entry point" do
    test "moves a task to another activity, renumbers, and drags its mapped cards along",
         %{board: board, stage: stage} do
      a1 = insert(:story_activity, board: board, position: 1)
      a2 = insert(:story_activity, board: board, position: 2)
      moving = insert(:story_task, story_activity: a1, position: 1)
      first = insert(:story_task, story_activity: a2, position: 1)
      second = insert(:story_task, story_activity: a2, position: 2)
      card = insert(:card, board: board, stage: stage)
      {:ok, card} = StoryMap.assign_card(card, %{story_task_id: moving.id})
      assert card.story_activity_id == a1.id

      Events.subscribe(board.id)

      assert {:ok, moved} = StoryMap.move_task(moving, a2.id, [first.id, moving.id, second.id])

      assert moved.story_activity_id == a2.id
      assert moved.position == 2
      assert Repo.get!(StoryTask, first.id).position == 1
      assert Repo.get!(StoryTask, second.id).position == 3
      assert Repo.get!(Card, card.id).story_activity_id == a2.id

      assert_receive {:card_upserted, %Card{id: card_id, story_activity_id: activity_id}}
      assert card_id == card.id
      assert activity_id == a2.id
      assert_receive {:story_map_changed, board_id}
      assert board_id == board.id
    end

    test "within one activity it is a pure renumber and moves no card", %{board: board, stage: stage} do
      activity = insert(:story_activity, board: board)
      a = insert(:story_task, story_activity: activity, position: 1)
      b = insert(:story_task, story_activity: activity, position: 2)
      card = insert(:card, board: board, stage: stage)
      {:ok, card} = StoryMap.assign_card(card, %{story_task_id: b.id})

      Events.subscribe(board.id)

      assert {:ok, moved} = StoryMap.move_task(b, activity.id, [b.id, a.id])

      assert moved.story_activity_id == activity.id
      assert moved.position == 1
      assert Repo.get!(StoryTask, a.id).position == 2
      assert Repo.get!(Card, card.id).story_activity_id == activity.id
      refute_receive {:card_upserted, _card}
    end

    test "it rejects a move to another board's activity and writes nothing", %{board: board} do
      activity = insert(:story_activity, board: board)
      task = insert(:story_task, story_activity: activity, position: 1)
      foreign = insert(:story_activity, board: insert(:board))

      assert {:error, changeset} = StoryMap.move_task(task, foreign.id, [task.id])
      assert "must belong to the same board" in errors_on(changeset).story_activity_id

      reloaded = Repo.get!(StoryTask, task.id)
      assert reloaded.story_activity_id == activity.id
      assert reloaded.position == 1
    end

    test "ids from another board are ignored by the renumber", %{board: board} do
      activity = insert(:story_activity, board: board)
      task = insert(:story_task, story_activity: activity, position: 1)
      foreign = insert(:story_task, story_activity: insert(:story_activity, board: insert(:board)), position: 9)

      assert {:ok, _moved} = StoryMap.move_task(task, activity.id, [foreign.id, task.id])

      assert Repo.get!(StoryTask, foreign.id).position == 9
      assert Repo.get!(StoryTask, task.id).position == 2
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

  describe "story-map position" do
    setup %{board: board, stage: stage} do
      activity = insert(:story_activity, board: board)
      task = insert(:story_task, story_activity: activity)
      other_task = insert(:story_task, story_activity: activity, position: 2)
      release = insert(:release, board: board)

      %{activity: activity, task: task, other_task: other_task, release: release, stage: stage}
    end

    test "without :position a card is appended last, and the whole cell is renumbered 1..n", ctx do
      place(ctx.stage, "First", ctx.task, ctx.release)
      place(ctx.stage, "Second", ctx.task, ctx.release)
      third = place(ctx.stage, "Third", ctx.task, ctx.release)

      assert cell_order(ctx.task, ctx.release) == ["First", "Second", "Third"]
      assert third.story_map_position == 3

      positions =
        Card
        |> where([c], c.story_task_id == ^ctx.task.id)
        |> Repo.all()
        |> Enum.map(& &1.story_map_position)
        |> Enum.sort()

      assert positions == [1, 2, 3]
    end

    test "with :position the card lands at that 0-based index", ctx do
      place(ctx.stage, "First", ctx.task, ctx.release)
      place(ctx.stage, "Second", ctx.task, ctx.release)
      moved = place(ctx.stage, "Jumped", ctx.task, ctx.release, %{position: 1})

      assert cell_order(ctx.task, ctx.release) == ["First", "Jumped", "Second"]
      assert moved.story_map_position == 2
    end

    test "the first-ever drag into an all-nil cell still lands where it was dropped", ctx do
      # Every card here is nil-positioned — exactly the day-one state, so the cards are inserted
      # already mapped rather than through assign_card/2 (which would position them). Writing
      # only the moved card's position would slam it to the top however far down the user
      # dropped it; renumbering the whole cell is what makes this land at the bottom.
      mapped = [
        story_activity_id: ctx.activity.id,
        story_task_id: ctx.task.id,
        release_id: ctx.release.id
      ]

      insert(:card, [stage: ctx.stage, title: "A", position: 1] ++ mapped)
      insert(:card, [stage: ctx.stage, title: "B", position: 2] ++ mapped)

      dropped = place(ctx.stage, "Dropped", ctx.task, ctx.release, %{position: 2})

      assert cell_order(ctx.task, ctx.release) == ["A", "B", "Dropped"]
      assert dropped.story_map_position == 3
    end

    test "an out-of-range index is clamped, not an error", ctx do
      place(ctx.stage, "First", ctx.task, ctx.release)
      high = place(ctx.stage, "High", ctx.task, ctx.release, %{position: 99})
      low = place(ctx.stage, "Low", ctx.task, ctx.release, %{position: -5})

      assert high.story_map_position == 2
      assert low.story_map_position == 1
      assert cell_order(ctx.task, ctx.release) == ["Low", "First", "High"]
    end

    test "the renumber is scoped to the target cell", ctx do
      other_column = place(ctx.stage, "Other column", ctx.other_task, ctx.release)
      other_lane_release = insert(:release, board: ctx.board, position: 2)
      other_lane = place(ctx.stage, "Other lane", ctx.task, other_lane_release)

      place(ctx.stage, "Target A", ctx.task, ctx.release)
      place(ctx.stage, "Target B", ctx.task, ctx.release, %{position: 0})

      assert Repo.get!(Card, other_column.id).story_map_position == other_column.story_map_position
      assert Repo.get!(Card, other_lane.id).story_map_position == other_lane.story_map_position
      assert cell_order(ctx.task, ctx.release) == ["Target B", "Target A"]
    end

    test "unassign_card/1 nils story_map_position along with the three columns", ctx do
      card = place(ctx.stage, "Mapped", ctx.task, ctx.release)
      assert card.story_map_position == 1

      {:ok, cleared} = StoryMap.unassign_card(card)

      assert cleared.story_activity_id == nil
      assert cleared.story_task_id == nil
      assert cleared.release_id == nil
      assert cleared.story_map_position == nil
    end

    test "a foreign id writes nothing at all — including no renumber", ctx do
      first = place(ctx.stage, "First", ctx.task, ctx.release)
      second = place(ctx.stage, "Second", ctx.task, ctx.release)
      foreign = insert(:release, board: insert(:board))
      intruder = insert(:card, stage: ctx.stage, title: "Intruder")

      assert {:error, _changeset} =
               StoryMap.assign_card(intruder, %{story_task_id: ctx.task.id, release_id: foreign.id})

      assert Repo.get!(Card, first.id).story_map_position == 1
      assert Repo.get!(Card, second.id).story_map_position == 2
      assert Repo.get!(Card, intruder.id).story_map_position == nil
    end

    test "a renumbered sibling keeps its updated_at; the moved card's is refreshed", ctx do
      # `updated_at` is this app's recency proxy behind two board-side orderings the story map
      # never shows — the Done column's render window (Cards.list_stage_cards/2) and everyone's
      # needs-you feed (Cards.needs_you_feed/1). A cell spans every stage by construction, so
      # re-stamping a sibling on a map drag would silently reorder both lenses.
      sibling = place(ctx.stage, "Sibling", ctx.task, ctx.release)
      moved = place(ctx.stage, "Moved", ctx.task, ctx.release)

      stale = ~U[2020-01-01 00:00:00Z]

      {2, _} =
        Repo.update_all(from(c in Card, where: c.id in ^[sibling.id, moved.id]), set: [updated_at: stale])

      {:ok, _} =
        StoryMap.assign_card(Repo.get!(Card, moved.id), %{
          story_task_id: ctx.task.id,
          release_id: ctx.release.id,
          position: 0
        })

      renumbered = Repo.get!(Card, sibling.id)
      assert renumbered.story_map_position == 2
      assert renumbered.updated_at == stale

      assert Repo.get!(Card, moved.id).updated_at != stale
    end

    test "exactly one {:card_upserted, _} is broadcast per placement — the moved card", ctx do
      place(ctx.stage, "First", ctx.task, ctx.release)
      place(ctx.stage, "Second", ctx.task, ctx.release)

      :ok = Events.subscribe(ctx.board.id)

      moved = place(ctx.stage, "Third", ctx.task, ctx.release, %{position: 0})
      moved_id = moved.id

      assert_receive {:card_upserted, %Card{id: ^moved_id}}
      refute_receive {:card_upserted, _other}, 100
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

  # The cell's cards in the order the grid would render them: story_map_position ascending
  # (nils last), ties broken by the board order list_cards/1 returns.
  defp cell_order(task, release) do
    Card
    |> where([c], c.story_task_id == ^task.id and c.release_id == ^release.id)
    |> order_by([c], asc: c.story_map_position, asc: c.stage_id, asc: c.position, asc: c.id)
    |> Repo.all()
    |> Enum.map(& &1.title)
  end

  defp place(stage, title, task, release, attrs \\ %{}) do
    card = insert(:card, stage: stage, title: title)
    attrs = Map.merge(%{story_task_id: task.id, release_id: release.id}, attrs)
    {:ok, placed} = StoryMap.assign_card(card, attrs)
    placed
  end

  describe "shared map view settings (RE257)" do
    setup do
      user = insert(:user)
      board = Boards.get_or_create_default_board(user)
      %{user: user, board: board}
    end

    test "view_defaults/0 is the one definition of the shared key set" do
      # RE257 — every setting that drives grid GEOMETRY lives here, because raw-pixel cursors
      # are only sound while every viewer renders the same grid. jsonb, so zoom is a string.
      # RE259 adds the four filter/focus keys: two lists and one nullable id.
      assert StoryMap.view_defaults() == %{
               "tray_open" => true,
               "zoom" => "compact",
               "hide_tasks" => false,
               "owner_filter" => [],
               "needs_input_filter" => false,
               "collapsed" => [],
               "focus" => nil
             }
    end

    test "view/1 merges the defaults under a board that has never been written", %{board: board} do
      assert StoryMap.view(board) == StoryMap.view_defaults()
    end

    test "view/1 drops a stored key that is no longer part of the set", %{board: board} do
      {1, _} =
        Repo.update_all(from(b in Board, where: b.id == ^board.id),
          set: [story_map_view: %{"tray_open" => false, "removed_setting" => 42}]
        )

      view = StoryMap.view(Repo.get!(Board, board.id))

      assert view == %{StoryMap.view_defaults() | "tray_open" => false}
      refute Map.has_key?(view, "removed_setting")
    end

    test "put_view/3 persists, broadcasts and returns the whole view", %{board: board} do
      :ok = StoryMap.subscribe_view(board.id)

      assert {:ok, %{"tray_open" => false}} = StoryMap.put_view(board, "tray_open", false)

      board_id = board.id
      assert_receive {:story_map_view_changed, ^board_id, %{"tray_open" => false}}

      assert Repo.get!(Board, board.id).story_map_view ==
               %{StoryMap.view_defaults() | "tray_open" => false}
    end

    test "put_view/3 reads the CURRENT row, so a concurrent key write is not clobbered",
         %{board: board} do
      # `board` is the caller's possibly-stale struct; another session has since written.
      {1, _} =
        Repo.update_all(from(b in Board, where: b.id == ^board.id),
          set: [story_map_view: %{"tray_open" => false}]
        )

      assert {:ok, %{"tray_open" => true}} = StoryMap.put_view(board, "tray_open", true)
    end

    test "put_view/3 rejects an unknown key and writes nothing", %{board: board} do
      :ok = StoryMap.subscribe_view(board.id)

      assert StoryMap.put_view(board, "shoe_size", 11) == {:error, :unknown_key}

      assert Repo.get!(Board, board.id).story_map_view == %{}
      refute_receive {:story_map_view_changed, _board_id, _view}, 100
    end

    test "put_view/3 stores zoom as a string the component's parser accepts", %{board: board} do
      assert {:ok, %{"zoom" => "full"}} = StoryMap.put_view(board, "zoom", "full")

      stored = StoryMap.view(Repo.get!(Board, board.id))["zoom"]
      assert RelayWeb.StoryMapComponents.parse_zoom(stored) == {:ok, :full}
      # And the default is parseable too — the LiveView's fallback destructures on it.
      assert {:ok, _level} = RelayWeb.StoryMapComponents.parse_zoom(StoryMap.view_defaults()["zoom"])
    end

    test "toggle_view/2 flips the COMMITTED row even when the caller's struct is stale",
         %{board: board} do
      :ok = StoryMap.subscribe_view(board.id)

      # This is the two-fast-clicks case: `board` still says tray_open=true (the assign a
      # LiveView would flip from, since its broadcast is still queued behind the second click)
      # while the row already says false. A `put_view(board, "tray_open", not true)` here would
      # write false a second time and the two clicks would net to ONE toggle.
      {1, _} =
        Repo.update_all(from(b in Board, where: b.id == ^board.id),
          set: [story_map_view: %{"tray_open" => false}]
        )

      assert {:ok, %{"tray_open" => true}} = StoryMap.toggle_view(board, "tray_open")

      board_id = board.id
      assert_receive {:story_map_view_changed, ^board_id, %{"tray_open" => true}}
      assert StoryMap.view(Repo.get!(Board, board.id))["tray_open"] == true
    end

    test "toggle_view/2 flips hide_tasks off its default and back", %{board: board} do
      assert {:ok, %{"hide_tasks" => true}} = StoryMap.toggle_view(board, "hide_tasks")
      assert {:ok, %{"hide_tasks" => false}} = StoryMap.toggle_view(board, "hide_tasks")
    end

    test "toggle_view/2 rejects an unknown key and writes nothing", %{board: board} do
      :ok = StoryMap.subscribe_view(board.id)

      assert StoryMap.toggle_view(board, "shoe_size") == {:error, :unknown_key}

      assert Repo.get!(Board, board.id).story_map_view == %{}
      refute_receive {:story_map_view_changed, _board_id, _view}, 100
    end

    test "merge_view/2 writes several keys in ONE broadcast", %{board: board} do
      :ok = StoryMap.subscribe_view(board.id)

      assert {:ok, view} =
               StoryMap.merge_view(board, %{"hide_tasks" => true, "focus" => 7})

      assert view["hide_tasks"] == true
      assert view["focus"] == 7

      board_id = board.id
      assert_receive {:story_map_view_changed, ^board_id, %{"focus" => 7}}
      # ONE broadcast, not one per key: "expand this activity AND turn Hide tasks off" is
      # atomic, which is the whole reason this writer exists.
      refute_receive {:story_map_view_changed, ^board_id, _view}, 100
    end

    test "merge_view/2 refuses a batch containing an unknown key and writes NOTHING",
         %{board: board} do
      :ok = StoryMap.subscribe_view(board.id)

      assert StoryMap.merge_view(board, %{"hide_tasks" => true, "shoe_size" => 11}) ==
               {:error, :unknown_key}

      assert Repo.get!(Board, board.id).story_map_view == %{}
      refute_receive {:story_map_view_changed, _board_id, _view}, 100
    end

    test "merge_view/2 re-reads the committed row, so a concurrent key write survives",
         %{board: board} do
      {1, _} =
        Repo.update_all(from(b in Board, where: b.id == ^board.id),
          set: [story_map_view: %{"tray_open" => false}]
        )

      assert {:ok, view} = StoryMap.merge_view(board, %{"needs_input_filter" => true})
      assert view["tray_open"] == false
    end

    test "put_view/3 still writes exactly one key through merge_view/2", %{board: board} do
      assert {:ok, %{"zoom" => "full", "tray_open" => true}} =
               StoryMap.put_view(board, "zoom", "full")
    end

    test "toggle_view/2 refuses a key whose default is not a boolean", %{board: board} do
      :ok = StoryMap.subscribe_view(board.id)

      # Without this guard `flip/1`'s "anything not true is off" fallback would replace the
      # "collapsed" LIST with `true` and every viewer's map would break.
      assert StoryMap.toggle_view(board, "collapsed") == {:error, :not_a_toggle}
      assert StoryMap.toggle_view(board, "focus") == {:error, :not_a_toggle}

      assert Repo.get!(Board, board.id).story_map_view == %{}
      refute_receive {:story_map_view_changed, _board_id, _view}, 100
    end

    test "toggle_view/2 flips needs_input_filter off its default and back", %{board: board} do
      assert {:ok, %{"needs_input_filter" => true}} =
               StoryMap.toggle_view(board, "needs_input_filter")

      assert {:ok, %{"needs_input_filter" => false}} =
               StoryMap.toggle_view(board, "needs_input_filter")
    end

    test "toggle_view_member/3 adds a member, then removes it", %{board: board} do
      assert {:ok, %{"owner_filter" => ["u:3"]}} =
               StoryMap.toggle_view_member(board, "owner_filter", "u:3")

      assert {:ok, %{"owner_filter" => ["u:3", "agent"]}} =
               StoryMap.toggle_view_member(board, "owner_filter", "agent")

      assert {:ok, %{"owner_filter" => ["agent"]}} =
               StoryMap.toggle_view_member(board, "owner_filter", "u:3")
    end

    test "toggle_view_member/3 flips the COMMITTED row, not the caller's stale struct",
         %{board: board} do
      # Two fast clicks computed from a render-lagged assign would both flip from the same
      # stale value — the reason toggle_view/2 exists, generalised to a list key.
      {1, _} =
        Repo.update_all(from(b in Board, where: b.id == ^board.id),
          set: [story_map_view: %{"collapsed" => [4]}]
        )

      assert {:ok, %{"collapsed" => []}} = StoryMap.toggle_view_member(board, "collapsed", 4)
    end

    test "toggle_view_member/4 merges `extra` into the SAME write", %{board: board} do
      :ok = StoryMap.subscribe_view(board.id)
      {:ok, _view} = StoryMap.merge_view(board, %{"focus" => 9})

      assert {:ok, %{"collapsed" => [4], "focus" => nil}} =
               StoryMap.toggle_view_member(board, "collapsed", 4, %{"focus" => nil})

      board_id = board.id
      assert_receive {:story_map_view_changed, ^board_id, %{"focus" => 9}}
      assert_receive {:story_map_view_changed, ^board_id, %{"collapsed" => [4], "focus" => nil}}
      refute_receive {:story_map_view_changed, ^board_id, _view}, 100
    end

    test "toggle_view_member/3 refuses a key whose default is not a list", %{board: board} do
      assert StoryMap.toggle_view_member(board, "hide_tasks", true) == {:error, :not_a_list}
      assert StoryMap.toggle_view_member(board, "shoe_size", 1) == {:error, :unknown_key}
      assert Repo.get!(Board, board.id).story_map_view == %{}
    end

    test "toggle_view_member/4 refuses an unknown key inside `extra`", %{board: board} do
      assert StoryMap.toggle_view_member(board, "collapsed", 4, %{"shoe_size" => 1}) ==
               {:error, :unknown_key}

      assert Repo.get!(Board, board.id).story_map_view == %{}
    end

    test "view/1 still drops a stored key outside the grown set", %{board: board} do
      {1, _} =
        Repo.update_all(from(b in Board, where: b.id == ^board.id),
          set: [story_map_view: %{"collapsed" => [1, 2], "removed_setting" => 42}]
        )

      view = StoryMap.view(Repo.get!(Board, board.id))

      assert view == %{StoryMap.view_defaults() | "collapsed" => [1, 2]}
      refute Map.has_key?(view, "removed_setting")
    end
  end
end
