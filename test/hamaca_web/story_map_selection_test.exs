defmodule HamacaWeb.StoryMapSelectionTest do
  @moduledoc """
  RE502 — the story map's selection math, unit-tested against plain structs. No DB, no
  LiveView: `HamacaWeb.StoryMapSelection` is pure, like `HamacaWeb.StoryMapGrid`.
  """
  use ExUnit.Case, async: true

  alias HamacaWeb.StagePickerComponents
  alias HamacaWeb.StoryMapGrid
  alias HamacaWeb.StoryMapSelection
  alias Schemas.Card
  alias Schemas.Release
  alias Schemas.Stage
  alias Schemas.StoryActivity
  alias Schemas.StoryStep

  defp activity(id, position), do: %StoryActivity{id: id, board_id: 1, name: "Activity #{id}", position: position}

  defp step(id, activity_id, position),
    do: %StoryStep{id: id, board_id: 1, story_activity_id: activity_id, name: "Step #{id}", position: position}

  defp release(id, position), do: %Release{id: id, board_id: 1, name: "Release #{id}", position: position}

  defp card(id, attrs), do: struct(%Card{id: id, board_id: 1, title: "Card #{id}", ref_number: id, owners: []}, attrs)

  defp stage(id, attrs), do: struct(%Stage{id: id, board_id: 1, name: "Stage #{id}", position: id}, attrs)

  # 2 releases × 2 steps (one per activity): A at (s1, r1), B at (s1, r2), C at (s2, r1).
  defp grid(collapsed \\ MapSet.new()) do
    StoryMapGrid.build(
      [activity(1, 1), activity(2, 2)],
      [step(10, 1, 1), step(20, 2, 1)],
      [release(100, 1), release(200, 2)],
      [
        card(1, story_activity_id: 1, story_step_id: 10, release_id: 100),
        card(2, story_activity_id: 1, story_step_id: 10, release_id: 200),
        card(3, story_activity_id: 2, story_step_id: 20, release_id: 100)
      ],
      nil,
      false,
      collapsed
    )
  end

  describe "toggle/2 (scenario 1)" do
    test "adds an absent id and removes a present one" do
      selection = [1] |> MapSet.new() |> StoryMapSelection.toggle(2) |> StoryMapSelection.toggle(1)

      assert selection == MapSet.new([2])
    end
  end

  describe "toggle_group/2 (scenario 2)" do
    test "a partly selected group is added whole" do
      assert StoryMapSelection.toggle_group(MapSet.new([1]), [1, 2, 3]) == MapSet.new([1, 2, 3])
    end

    test "a fully selected group is removed, leaving the rest of the selection" do
      assert StoryMapSelection.toggle_group(MapSet.new([1, 2, 3, 9]), [1, 2, 3]) == MapSet.new([9])
    end

    test "an empty group is a no-op" do
      selection = MapSet.new([4, 5])
      assert StoryMapSelection.toggle_group(selection, []) == selection
    end
  end

  describe "group_state/2 (scenario 3)" do
    test "some, all, none, and an empty group is none" do
      assert StoryMapSelection.group_state(MapSet.new([1]), [1, 2]) == :some
      assert StoryMapSelection.group_state(MapSet.new([1, 2]), [1, 2]) == :all
      assert StoryMapSelection.group_state(MapSet.new(), [1]) == :none
      assert StoryMapSelection.group_state(MapSet.new([1]), []) == :none
    end
  end

  describe "group_ids/3 (scenario 4)" do
    test "a column's ids are every card in that column, across lanes" do
      assert Enum.sort(StoryMapSelection.group_ids(grid(), :column, "s:10")) == [1, 2]
    end

    test "a lane's ids are every card in that lane, across columns" do
      assert Enum.sort(StoryMapSelection.group_ids(grid(), :lane, "r:100")) == [1, 3]
    end

    test "a collapsed activity's cards are not in the lane" do
      assert StoryMapSelection.group_ids(grid(MapSet.new([2])), :lane, "r:100") == [1]
    end
  end

  describe "marks/2 (scenario 5)" do
    test "mixed stages are all :some; one shared stage is :all" do
      assert StoryMapSelection.marks([card(1, stage_id: 3), card(2, stage_id: 3), card(3, stage_id: 5)], :stage) ==
               %{3 => :some, 5 => :some}

      assert StoryMapSelection.marks([card(1, stage_id: 3), card(2, stage_id: 3)], :stage) == %{3 => :all}
    end

    test "a nil release is the (No release) row id" do
      assert StoryMapSelection.marks([card(1, release_id: nil), card(2, release_id: nil)], :release) ==
               %{StagePickerComponents.no_release_id() => :all}

      assert StagePickerComponents.no_release_id() == "none"
    end

    test "a nil step contributes no key" do
      assert StoryMapSelection.marks([card(1, story_step_id: 7), card(2, story_step_id: nil)], :step) ==
               %{7 => :some}
    end

    test "no cards, no marks" do
      assert StoryMapSelection.marks([], :stage) == %{}
    end
  end

  describe "order_by_map_position/4 (scenario 6)" do
    test "release, then activity, then step, then position, then id" do
      releases = [release(1, 1), release(2, 2)]
      activities = [activity(11, 1), activity(12, 2)]
      steps = [step(21, 11, 1), step(22, 11, 2), step(23, 12, 1)]

      p = card(1, release_id: 2, story_activity_id: 11, story_step_id: 21)
      q = card(2, release_id: 1, story_activity_id: 12, story_step_id: 23)
      r = card(3, release_id: 1, story_activity_id: 11, story_step_id: 21, story_map_position: 2)
      s = card(4, release_id: 1, story_activity_id: 11, story_step_id: 21, story_map_position: 1)
      t = card(5, release_id: nil, story_activity_id: 11, story_step_id: 21)

      ordered = StoryMapSelection.order_by_map_position([p, q, r, s, t], activities, steps, releases)

      assert Enum.map(ordered, & &1.id) == [s.id, r.id, q.id, p.id, t.id]
    end

    test "a step-less card sorts after its activity's steps" do
      activities = [activity(11, 1)]
      steps = [step(21, 11, 1)]
      no_step = card(1, release_id: nil, story_activity_id: 11)
      stepped = card(2, release_id: nil, story_activity_id: 11, story_step_id: 21)

      assert [no_step, stepped]
             |> StoryMapSelection.order_by_map_position(activities, steps, [])
             |> Enum.map(& &1.id) == [2, 1]
    end
  end

  describe "prune/2 and selectable_ids/1 (scenario 7)" do
    test "prune is the intersection with the selectable ids" do
      assert StoryMapSelection.prune(MapSet.new([1, 2, 3]), MapSet.new([2, 3, 4])) == MapSet.new([2, 3])
    end

    test "selectable_ids excludes an unmapped card" do
      cards = [card(1, story_activity_id: 11), card(2, story_activity_id: nil)]

      assert StoryMapSelection.selectable_ids(cards) == MapSet.new([1])
    end
  end

  describe "visible_cards/5" do
    test "Hide complete drops a top-level complete stage's cards" do
      stages = [stage(1, category: :planning), stage(2, category: :complete)]
      cards = [card(1, stage_id: 1), card(2, stage_id: 2)]

      assert cards |> StoryMapSelection.visible_cards(stages, [], false, true) |> Enum.map(& &1.id) == [1]
      assert cards |> StoryMapSelection.visible_cards(stages, [], false, false) |> Enum.map(& &1.id) == [1, 2]
    end

    test "the owner filter narrows the list" do
      owned = card(1, stage_id: 1, owners: [%Schemas.CardOwner{actor_type: :agent}])
      cards = [owned, card(2, stage_id: 1)]

      assert cards |> StoryMapSelection.visible_cards([], ["agent"], false, false) |> Enum.map(& &1.id) == [1]
    end
  end

  describe "confirm_copy/3" do
    test "one live run among three cards reads singular, with an others button" do
      assert StoryMapSelection.confirm_copy(1, 3, "Backlog") == %{
               title: "1 of 3 cards has a live run",
               cancel_all: "Cancel 1 run & move all 3",
               others: "Move the other 2 only",
               consequence: "Moving it to Backlog cancels that run and frees its runner slot."
             }
    end

    test "several live runs read plural" do
      copy = StoryMapSelection.confirm_copy(2, 5, "Done")

      assert copy.title == "2 of 5 cards have live runs"
      assert copy.cancel_all == "Cancel 2 runs & move all 5"
      assert copy.others == "Move the other 3 only"
      assert copy.consequence == "Moving them to Done cancels those runs and frees their runner slots."
    end

    test "every card running hides the others button" do
      copy = StoryMapSelection.confirm_copy(1, 1, "Backlog")

      assert copy.title == "1 of 1 card has a live run"
      assert copy.cancel_all == "Cancel 1 run & move all 1"
      assert copy.others == nil
    end
  end

  describe "confirm modes" do
    test "confirm_modes/0 is the closed set" do
      assert StoryMapSelection.confirm_modes() == [:all, :others]
    end

    test "parse_confirm_mode/1 maps the wire strings and rejects anything else" do
      assert StoryMapSelection.parse_confirm_mode("all") == {:ok, :all}
      assert StoryMapSelection.parse_confirm_mode("others") == {:ok, :others}
      assert StoryMapSelection.parse_confirm_mode("x") == :error
    end
  end

  describe "StoryMapGrid.select_box_id/2" do
    test "dashes the key under a column or lane prefix" do
      assert StoryMapGrid.select_box_id(:column, "s:7") == "story-map-select-col-s-7"
      assert StoryMapGrid.select_box_id(:lane, "r:none") == "story-map-select-lane-r-none"
    end
  end
end
