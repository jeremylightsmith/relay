defmodule RelayWeb.StoryMapDeleteGuardTest do
  @moduledoc """
  RE261 — the guard-vs-display invariant, pinned in the ONE direction that matters.

  The greyed ✕ is driven by `RelayWeb.StoryMapGrid`'s counts; the refusal is driven by
  `Relay.StoryMap`'s own non-archived count. They agree exactly for activities and tasks. For
  RELEASES the grid count is larger: a mapped card with no release **displays** in the last
  lane, which the server's `release_id == id` check does not see. That direction is the safe
  one — the UI may block a delete the server would allow (harmless: the button is greyed and
  nobody can click it), but the server never refuses a delete the UI presented as clickable.
  Inverting it would ship a dead button, so it is pinned here over a fixture board that HAS
  strays.
  """
  use Relay.DataCase, async: true

  alias Relay.Cards
  alias Relay.StoryMap
  alias RelayWeb.StoryMapGrid

  setup do
    board = insert(:board)
    stage = insert(:stage, board: board)

    a1 = insert(:story_activity, board: board, position: 1)
    a2 = insert(:story_activity, board: board, position: 2)
    a3 = insert(:story_activity, board: board, position: 3)
    t1 = insert(:story_task, story_activity: a1, position: 1)
    t2 = insert(:story_task, story_activity: a2, position: 1)
    r1 = insert(:release, board: board, position: 1)
    r2 = insert(:release, board: board, position: 2)

    # In R1 for real.
    {:ok, _} = StoryMap.assign_card(insert(:card, board: board, stage: stage), %{story_task_id: t1.id, release_id: r1.id})
    # A STRAY: mapped, no release — the grid parks it on the LAST lane (R2), the server does not.
    {:ok, _} = StoryMap.assign_card(insert(:card, board: board, stage: stage), %{story_task_id: t1.id})
    # Archived: invisible to Cards.list_cards/1, and must be invisible to the guard too.
    archived = insert(:card, board: board, stage: stage)
    {:ok, archived} = StoryMap.assign_card(archived, %{story_activity_id: a3.id, release_id: r2.id})
    {:ok, _} = Cards.archive_card(archived)

    grid =
      StoryMapGrid.build(
        StoryMap.list_activities(board),
        StoryMap.list_tasks(board),
        StoryMap.list_releases(board),
        Cards.list_cards(board)
      )

    %{board: board, grid: grid, a1: a1, a2: a2, a3: a3, t1: t1, t2: t2, r1: r1, r2: r2}
  end

  test "the counts the header shows", ctx do
    assert band_count(ctx.grid, ctx.a1.id) == 2
    assert band_count(ctx.grid, ctx.a2.id) == 0
    assert band_count(ctx.grid, ctx.a3.id) == 0
    assert column_count(ctx.grid, ctx.t1.id) == 2
    assert column_count(ctx.grid, ctx.t2.id) == 0
    assert lane_count(ctx.grid, ctx.r1.id) == 1
    # The stray parks here on display only.
    assert lane_count(ctx.grid, ctx.r2.id) == 1
  end

  test "everything the grid counts 0 for — an ENABLED ✕ — the server actually deletes", ctx do
    assert column_count(ctx.grid, ctx.t2.id) == 0
    assert {:ok, _} = StoryMap.delete_task(ctx.t2)

    assert band_count(ctx.grid, ctx.a2.id) == 0
    assert {:ok, _} = StoryMap.delete_activity(ctx.a2)

    # Holds only an ARCHIVED card, so the grid counts 0 and the server must agree.
    assert band_count(ctx.grid, ctx.a3.id) == 0
    assert {:ok, _} = StoryMap.delete_activity(ctx.a3)
  end

  test "activities and tasks agree exactly — a non-zero count is a refusal", ctx do
    assert band_count(ctx.grid, ctx.a1.id) > 0
    assert {:error, :not_empty} = StoryMap.delete_activity(ctx.a1)

    assert column_count(ctx.grid, ctx.t1.id) > 0
    assert {:error, :not_empty} = StoryMap.delete_task(ctx.t1)
  end

  test "releases are the only gap, and it leans the SAFE way", ctx do
    # R1 genuinely holds a card: both agree.
    assert lane_count(ctx.grid, ctx.r1.id) > 0
    assert {:error, :not_empty} = StoryMap.delete_release(ctx.r1)

    # R2 displays the release-less stray, so the UI blocks it — while the server would allow
    # it. UI-blocked ⇒ server-allowed is fine (a greyed button is unclickable); the inverse
    # would be a dead button, and this assertion is what stops a future change inverting it.
    assert lane_count(ctx.grid, ctx.r2.id) > 0
    assert {:ok, _} = StoryMap.delete_release(ctx.r2)
  end

  defp band_count(grid, activity_id) do
    Enum.find_value(grid.bands, fn band -> band.activity.id == activity_id && band.count end)
  end

  defp column_count(grid, task_id) do
    Enum.find_value(grid.columns, fn column -> column.key == "t:#{task_id}" && column.count end)
  end

  defp lane_count(grid, release_id) do
    Enum.find_value(grid.lanes, fn lane -> lane.key == "r:#{release_id}" && lane.count end)
  end
end
