defmodule Relay.Runs.SchedulerDependenciesTest do
  @moduledoc "RE93 — the snapshot carries blocked_by, and the real planner refuses to pull a blocked card."
  use Relay.DataCase, async: true

  alias Relay.Cards
  alias Relay.Runs.Scheduler
  alias Relay.Runs.Scheduler.Server, as: SchedulerServer

  defmodule NoRuns do
    @moduledoc false
    def active_runs(_board_id), do: []
  end

  setup do
    board = insert(:board, key: "RE")
    next_up = insert(:stage, board: board, name: "Next up", category: :unstarted, position: 1)
    code = insert(:stage, board: board, name: "Code", category: :in_progress, type: :work, position: 2)
    done = insert(:stage, board: board, name: "Done", category: :complete, position: 9)

    insert(:flow,
      board: board,
      key: "code",
      enabled: true,
      pulls_from_stage_id: next_up.id,
      works_in_stage_id: code.id
    )

    a = insert(:card, stage: next_up, ref_number: 1, status: :ready)
    b = insert(:card, stage: next_up, ref_number: 2, status: :ready)
    insert(:card_owner, card: a)
    insert(:card_owner, card: b)

    %{board: board, next_up: next_up, done: done, a: a, b: b}
  end

  defp snapshot(board), do: elem(SchedulerServer.build_snapshot(board.id, NoRuns), 0)

  test "build_snapshot/2 carries the unmet blocker ids onto the card map", ctx do
    {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])

    cards = Map.new(snapshot(ctx.board).cards, &{&1.id, &1})
    assert cards[ctx.a.id].blocked_by == [ctx.b.id]
    assert cards[ctx.b.id].blocked_by == []
  end

  test "explain/2 reports the dependency wait and no dispatch is planned for the blocked card", ctx do
    {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
    snapshot = snapshot(ctx.board)

    assert %{verdict: :blocked_by_dependencies, evidence: %{blocked_by: ["RE2"]}} =
             Scheduler.explain(snapshot, ctx.a.id)

    refute Enum.any?(Scheduler.plan(snapshot).dispatches, &match?({:start, id, _, _} when id == ctx.a.id, &1))
  end

  test "moving the blocker into a top-level Done column releases the dependent", ctx do
    {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
    {:ok, _} = Cards.move_card(ctx.b, ctx.done, 0, :agent)

    snapshot = snapshot(ctx.board)
    cards = Map.new(snapshot.cards, &{&1.id, &1})

    assert cards[ctx.a.id].blocked_by == []
    refute match?(%{verdict: :blocked_by_dependencies}, Scheduler.explain(snapshot, ctx.a.id))
  end
end
