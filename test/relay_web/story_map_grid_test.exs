defmodule RelayWeb.StoryMapGridTest do
  @moduledoc """
  RE264 — the story map's placement rules, unit-tested against plain structs. No DB, no
  LiveView: every rule the artboard (`docs/designs/Relay Story Map.dc.html`) encodes in `eff/1`
  lives in `RelayWeb.StoryMapGrid`, and this is where it is proven.
  """
  use ExUnit.Case, async: true

  alias RelayWeb.StoryMapGrid
  alias Schemas.Card
  alias Schemas.Release
  alias Schemas.StoryActivity
  alias Schemas.StoryTask

  defp activity(id, position), do: %StoryActivity{id: id, board_id: 1, name: "Activity #{id}", position: position}

  defp task(id, activity_id, position),
    do: %StoryTask{id: id, board_id: 1, story_activity_id: activity_id, name: "Task #{id}", position: position}

  defp release(id, position), do: %Release{id: id, board_id: 1, name: "Release #{id}", position: position}

  defp card(id, placement \\ []), do: struct(%Card{id: id, board_id: 1, title: "Card #{id}", ref_number: id}, placement)

  describe "column placement" do
    test "a card with a task lands in that task's column and its release's lane" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1)],
          [task(10, 1, 1)],
          [release(100, 1), release(200, 2)],
          [card(5, story_activity_id: 1, story_task_id: 10, release_id: 100)]
        )

      assert Map.keys(grid.cells) == [{"t:10", "r:100"}]
      assert [%Card{id: 5}] = grid.cells[{"t:10", "r:100"}]
      assert grid.unmapped == []
      assert grid.total == 1
    end

    test "a card with an activity and no task lands in the No task yet column" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1)],
          [task(10, 1, 1)],
          [release(100, 1)],
          [card(5, story_activity_id: 1, release_id: 100)]
        )

      assert [%Card{id: 5}] = grid.cells[{"nt:1", "r:100"}]

      assert Enum.map(grid.columns, & &1.key) == ["nt:1", "t:10"]
      assert [no_task, task_column] = grid.columns
      assert no_task.no_task? and not no_task.last_of_activity?
      assert not task_column.no_task? and task_column.last_of_activity?
    end

    test "the No task yet column does not render when no card needs it" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1)],
          [task(10, 1, 1)],
          [release(100, 1)],
          [card(5, story_activity_id: 1, story_task_id: 10, release_id: 100)]
        )

      assert Enum.map(grid.columns, & &1.key) == ["t:10"]
      assert [%{span: 1, start: 0}] = grid.bands
    end

    test "an activity with no tasks still yields one empty column with span 1" do
      grid = StoryMapGrid.build([activity(1, 1)], [], [release(100, 1)], [])

      assert [%{key: "nt:1", no_task?: true, last_of_activity?: true}] = grid.columns
      assert [%{span: 1, start: 0, count: 0}] = grid.bands
      assert grid.cells == %{}
    end

    test "a card is placed by its task's activity, not by a disagreeing story_activity_id" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1), activity(2, 2)],
          [task(20, 2, 1)],
          [release(100, 1)],
          [card(5, story_activity_id: 1, story_task_id: 20, release_id: 100)]
        )

      assert [%Card{id: 5}] = grid.cells[{"t:20", "r:100"}]
      assert [%{count: 0}, %{count: 1}] = grid.bands
    end

    test "bands span every column of their activity, in order, with their card counts" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1), activity(2, 2)],
          [task(10, 1, 1), task(11, 1, 2), task(20, 2, 1)],
          [release(100, 1)],
          [
            card(5, story_activity_id: 1, release_id: 100),
            card(6, story_activity_id: 1, story_task_id: 11, release_id: 100),
            card(7, story_activity_id: 2, story_task_id: 20, release_id: 100)
          ]
        )

      assert Enum.map(grid.columns, & &1.key) == ["nt:1", "t:10", "t:11", "t:20"]
      assert [band1, band2] = grid.bands
      assert %{span: 3, start: 0, count: 2} = band1
      assert %{span: 1, start: 3, count: 1} = band2
      assert band1.activity.id == 1 and band2.activity.id == 2
    end
  end

  describe "the tray" do
    test "a card with no activity lands in the tray even when it has a release" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1)],
          [task(10, 1, 1)],
          [release(100, 1)],
          [card(5, release_id: 100)]
        )

      assert [%Card{id: 5}] = grid.unmapped
      assert grid.cells == %{}
      assert [%{count: 0}] = grid.lanes
    end

    test "a card pointing at an activity this board does not have lands in the tray" do
      grid = StoryMapGrid.build([activity(1, 1)], [], [release(100, 1)], [card(5, story_activity_id: 99)])

      assert [%Card{id: 5}] = grid.unmapped
      assert grid.cells == %{}
    end
  end

  describe "lane placement" do
    test "a mapped card with no release lands in the last lane" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1)],
          [task(10, 1, 1)],
          [release(100, 1), release(200, 2), release(300, 3)],
          [card(5, story_activity_id: 1, story_task_id: 10)]
        )

      assert [%Card{id: 5}] = grid.cells[{"t:10", "r:300"}]
      assert Enum.map(grid.lanes, & &1.count) == [0, 0, 1]
    end

    test "…and still does after the lanes are reordered" do
      reordered = [release(300, 1), release(100, 2), release(200, 3)]

      grid =
        StoryMapGrid.build(
          [activity(1, 1)],
          [task(10, 1, 1)],
          reordered,
          [card(5, story_activity_id: 1, story_task_id: 10)]
        )

      assert Enum.map(grid.lanes, & &1.key) == ["r:300", "r:100", "r:200"]
      assert [%Card{id: 5}] = grid.cells[{"t:10", "r:200"}]
    end

    test "a release the board does not have falls into the last lane too" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1)],
          [task(10, 1, 1)],
          [release(100, 1), release(200, 2)],
          [card(5, story_activity_id: 1, story_task_id: 10, release_id: 999)]
        )

      assert [%Card{id: 5}] = grid.cells[{"t:10", "r:200"}]
    end

    test "a board with zero releases produces one (No release) lane and loses no card" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1)],
          [task(10, 1, 1)],
          [],
          [
            card(5, story_activity_id: 1, story_task_id: 10, release_id: 100),
            card(6, story_activity_id: 1, story_task_id: 10)
          ]
        )

      assert [%{key: "r:none", release: nil, count: 2}] = grid.lanes
      assert [%Card{id: 5}, %Card{id: 6}] = grid.cells[{"t:10", "r:none"}]
      assert grid.unmapped == []
    end
  end

  describe "ordering and the no-card-can-disappear invariant" do
    test "cards keep list_cards/1 order inside a cell and in the tray" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1)],
          [task(10, 1, 1)],
          [release(100, 1)],
          [
            card(1, story_activity_id: 1, story_task_id: 10, release_id: 100),
            card(2),
            card(3, story_activity_id: 1, story_task_id: 10, release_id: 100),
            card(4)
          ]
        )

      assert Enum.map(grid.cells[{"t:10", "r:100"}], & &1.id) == [1, 3]
      assert Enum.map(grid.unmapped, & &1.id) == [2, 4]
    end

    test "every card appears exactly once across cells ∪ unmapped, and total is the input count" do
      activities = [activity(1, 1), activity(2, 2), activity(3, 3)]
      tasks = [task(10, 1, 1), task(11, 1, 2), task(20, 2, 1)]
      releases = [release(100, 1), release(200, 2)]

      cards = [
        card(1, story_activity_id: 1, story_task_id: 10, release_id: 100),
        card(2, story_activity_id: 1, story_task_id: 11),
        card(3, story_activity_id: 1, release_id: 200),
        card(4, story_activity_id: 2, story_task_id: 20, release_id: 999),
        card(5, story_activity_id: 3),
        card(6, story_activity_id: 3, story_task_id: 10, release_id: 100),
        card(7, release_id: 100),
        card(8),
        card(9, story_activity_id: 42, release_id: 200)
      ]

      grid = StoryMapGrid.build(activities, tasks, releases, cards)

      placed = grid.cells |> Map.values() |> List.flatten() |> Enum.map(& &1.id)
      all = Enum.sort(placed ++ Enum.map(grid.unmapped, & &1.id))

      assert all == Enum.sort(Enum.map(cards, & &1.id))
      assert length(all) == length(cards)
      assert grid.total == length(cards)

      lane_total = grid.lanes |> Enum.map(& &1.count) |> Enum.sum()
      assert lane_total + length(grid.unmapped) == grid.total
    end
  end

  describe "the draft column (RE263)" do
    test "build/4 still behaves exactly as before — the draft argument defaults to none" do
      four = StoryMapGrid.build([activity(1, 1)], [task(10, 1, 1)], [release(100, 1)], [])
      five = StoryMapGrid.build([activity(1, 1)], [task(10, 1, 1)], [release(100, 1)], [], nil)

      assert four == five
      assert Enum.map(four.columns, & &1.key) == ["t:10"]
      assert Enum.all?(four.columns, &(&1.draft? == false and &1.bare? == false))
    end

    test "an :activity or :release draft is chrome — the view model is untouched" do
      plain = StoryMapGrid.build([activity(1, 1)], [task(10, 1, 1)], [release(100, 1)], [])

      assert StoryMapGrid.build([activity(1, 1)], [task(10, 1, 1)], [release(100, 1)], [], :activity) == plain
      assert StoryMapGrid.build([activity(1, 1)], [task(10, 1, 1)], [release(100, 1)], [], :release) == plain
    end

    test "a {:task, id} draft appends one draft column, grows the span and takes last_of_activity?" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1), activity(2, 2)],
          [task(10, 1, 1), task(11, 1, 2), task(20, 2, 1)],
          [release(100, 1)],
          [],
          {:task, 1}
        )

      assert Enum.map(grid.columns, & &1.key) == ["t:10", "t:11", "draft:1", "t:20"]
      assert [_first, second, draft, _other] = grid.columns
      assert draft.draft? and draft.last_of_activity? and draft.task == nil
      assert draft.activity.id == 1
      refute second.last_of_activity?
      assert [%{span: 3, start: 0}, %{span: 1, start: 3}] = grid.bands
    end

    test "for an activity with no tasks and no task-less cards the draft REPLACES the placeholder" do
      grid = StoryMapGrid.build([activity(1, 1)], [], [release(100, 1)], [], {:task, 1})

      assert [%{key: "draft:1", draft?: true, last_of_activity?: true}] = grid.columns
      assert [%{span: 1, start: 0}] = grid.bands
    end

    test "an activity with task-less cards keeps its No task yet column beside the draft" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1)],
          [],
          [release(100, 1)],
          [card(5, story_activity_id: 1, release_id: 100)],
          {:task, 1}
        )

      assert Enum.map(grid.columns, & &1.key) == ["nt:1", "draft:1"]
      assert [no_task, draft] = grid.columns
      refute no_task.bare?
      refute no_task.last_of_activity?
      assert draft.last_of_activity?
      assert [%Card{id: 5}] = grid.cells[{"nt:1", "r:100"}]
    end

    test "bare? marks the placeholder column that holds no cards, and only that one" do
      bare = StoryMapGrid.build([activity(1, 1)], [], [release(100, 1)], [])
      assert [%{key: "nt:1", bare?: true}] = bare.columns

      occupied =
        StoryMapGrid.build(
          [activity(1, 1)],
          [],
          [release(100, 1)],
          [card(5, story_activity_id: 1, release_id: 100)]
        )

      assert [%{key: "nt:1", bare?: false}] = occupied.columns
    end

    test "a draft naming an activity this board does not have changes nothing" do
      plain = StoryMapGrid.build([activity(1, 1)], [task(10, 1, 1)], [release(100, 1)], [])

      assert StoryMapGrid.build([activity(1, 1)], [task(10, 1, 1)], [release(100, 1)], [], {:task, 999}) == plain
    end

    test "the draft column gets no cells, and the invariant still holds with a draft open" do
      cards = [
        card(1, story_activity_id: 1, story_task_id: 10, release_id: 100),
        card(2, story_activity_id: 1, release_id: 100),
        card(3, release_id: 100)
      ]

      grid = StoryMapGrid.build([activity(1, 1)], [task(10, 1, 1)], [release(100, 1)], cards, {:task, 1})

      refute Enum.any?(Map.keys(grid.cells), fn {column_key, _lane} -> column_key == "draft:1" end)

      placed = grid.cells |> Map.values() |> List.flatten() |> Enum.map(& &1.id)
      assert Enum.sort(placed ++ Enum.map(grid.unmapped, & &1.id)) == [1, 2, 3]
      assert grid.total == 3
    end
  end

  describe "cell_dom_id/2" do
    test "turns the keys into a selector-safe id" do
      assert StoryMapGrid.cell_dom_id("t:10", "r:100") == "story-map-cell-t-10-r-100"
      assert StoryMapGrid.cell_dom_id("nt:1", "r:none") == "story-map-cell-nt-1-r-none"
    end
  end

  describe "cell ordering — story_map_position, ascending, nils last" do
    test "positioned cards sort ascending ahead of nil-position cards in the same cell" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1)],
          [task(10, 1, 1)],
          [release(100, 1)],
          [
            card(1, story_activity_id: 1, story_task_id: 10, release_id: 100),
            card(2, story_activity_id: 1, story_task_id: 10, release_id: 100, story_map_position: 2),
            card(3, story_activity_id: 1, story_task_id: 10, release_id: 100, story_map_position: 1)
          ]
        )

      assert Enum.map(grid.cells[{"t:10", "r:100"}], & &1.id) == [3, 2, 1]
    end

    test "nil-position cards keep list_cards/1's board order beneath them" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1)],
          [task(10, 1, 1)],
          [release(100, 1)],
          [
            card(7, story_activity_id: 1, story_task_id: 10, release_id: 100),
            card(8, story_activity_id: 1, story_task_id: 10, release_id: 100),
            card(9, story_activity_id: 1, story_task_id: 10, release_id: 100, story_map_position: 5)
          ]
        )

      assert Enum.map(grid.cells[{"t:10", "r:100"}], & &1.id) == [9, 7, 8]
    end

    test "the tray ignores story_map_position entirely" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1)],
          [],
          [release(100, 1)],
          [card(1, story_map_position: 9), card(2, story_map_position: 1), card(3)]
        )

      assert Enum.map(grid.unmapped, & &1.id) == [1, 2, 3]
    end
  end

  describe "decode_placement/2 — the key format, parsed where it is defined" do
    test "a task column plus a release lane" do
      assert StoryMapGrid.decode_placement("t:7", "r:2") == {:ok, %{story_task_id: 7, release_id: 2}}
    end

    test "a No task yet column carries the activity, never a task" do
      assert StoryMapGrid.decode_placement("nt:3", "r:2") ==
               {:ok, %{story_activity_id: 3, release_id: 2}}
    end

    test "the synthetic (No release) lane decodes to a nil release" do
      assert StoryMapGrid.decode_placement("nt:3", "r:none") ==
               {:ok, %{story_activity_id: 3, release_id: nil}}
    end

    test "round-trips every key shape build/4 emits" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1), activity(2, 2)],
          [task(10, 1, 1)],
          [release(100, 1)],
          [card(5, story_activity_id: 1, release_id: 100)]
        )

      for column <- grid.columns, lane <- grid.lanes do
        assert {:ok, _placement} = StoryMapGrid.decode_placement(column.key, lane.key)
      end
    end

    test "garbage is :error, never a guess" do
      for {column, lane} <- [
            {"x:1", "r:1"},
            {"t:", "r:1"},
            {"t:abc", "r:1"},
            {"t:1", "r:abc"},
            {"t:1", "later"},
            {"", ""},
            {"t:0", "r:1"}
          ] do
        assert StoryMapGrid.decode_placement(column, lane) == :error,
               "#{column} / #{lane} should not decode"
      end
    end
  end

  describe "cell_element_id/3 — the one definition of the : → - rule" do
    test "cell_dom_id/2 is the cell prefix of the same rule" do
      assert StoryMapGrid.cell_element_id("cell", "t:10", "r:100") == "story-map-cell-t-10-r-100"
      assert StoryMapGrid.cell_dom_id("t:10", "r:100") == "story-map-cell-t-10-r-100"
      assert StoryMapGrid.cell_element_id("add", "nt:3", "r:none") == "story-map-add-nt-3-r-none"
    end
  end

  describe "columns[].count (RE261)" do
    test "each column carries the number of cards in it, across every lane" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1)],
          [task(10, 1, 1), task(11, 1, 2)],
          [release(100, 1), release(200, 2)],
          [
            card(5, story_activity_id: 1, story_task_id: 10, release_id: 100),
            card(6, story_activity_id: 1, story_task_id: 10, release_id: 200),
            card(7, story_activity_id: 1, story_task_id: 11, release_id: 100)
          ]
        )

      assert Enum.map(grid.columns, &{&1.key, &1.count}) == [{"t:10", 2}, {"t:11", 1}]
      assert [%{count: 3}] = grid.bands
    end

    test "an empty task column counts 0 and a No task yet column counts its own cards" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1)],
          [task(10, 1, 1)],
          [release(100, 1)],
          [card(5, story_activity_id: 1, release_id: 100)]
        )

      assert Enum.map(grid.columns, &{&1.key, &1.count}) == [{"nt:1", 1}, {"t:10", 0}]
    end

    test "the draft column counts 0 and the band total is the sum of its columns" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1), activity(2, 2)],
          [task(10, 1, 1), task(20, 2, 1)],
          [release(100, 1)],
          [
            card(5, story_activity_id: 1, story_task_id: 10, release_id: 100),
            card(6, story_activity_id: 2, story_task_id: 20, release_id: 100)
          ],
          {:task, 1}
        )

      by_key = Map.new(grid.columns, &{&1.key, &1.count})
      assert by_key["draft:1"] == 0
      assert by_key["t:10"] == 1
      assert Enum.map(grid.bands, & &1.count) == [1, 1]
    end

    test "the sum of every column count plus the tray is the total" do
      grid =
        StoryMapGrid.build(
          [activity(1, 1)],
          [task(10, 1, 1)],
          [release(100, 1)],
          [
            card(5, story_activity_id: 1, story_task_id: 10, release_id: 100),
            card(6, story_activity_id: 99, release_id: 100),
            card(7)
          ]
        )

      column_total = grid.columns |> Enum.map(& &1.count) |> Enum.sum()
      assert column_total + length(grid.unmapped) == grid.total
    end
  end
end
