defmodule Hamaca.Runs.TalkIsolationTest do
  @moduledoc """
  RE366 — the server decides, per talk turn, whether it runs read-only in the runner's shared
  clean checkout (`:shared_clean`) or in the card's own worktree (`:exclusive`). Exclusive only
  when the card has live per-card work: an active run of an exclusive flow, or any runner on the
  board declaring it holds the card's worktree.
  """
  use Hamaca.DataCase, async: true

  alias Hamaca.Cards
  alias Hamaca.Runs
  alias Schemas.Flow
  alias Schemas.Runner

  setup do
    board = insert(:board)
    stage = insert(:stage, board: board)
    card = insert(:card, board: board, stage: stage)

    %{board: board, stage: stage, card: card, ref: Cards.ref(board, card)}
  end

  test "a card with no runs and no runner rows talks in the shared clean checkout", ctx do
    isolation = Runs.talk_isolation(ctx.card)

    assert isolation == :shared_clean
    assert isolation in Flow.isolation_classes()
  end

  test "an active run of a shared_clean flow keeps talk shared", ctx do
    flow = insert(:flow, board: ctx.board, isolation: :shared_clean)
    insert(:run, card: ctx.card, flow_id: flow.id, status: :running)

    assert Runs.talk_isolation(ctx.card) == :shared_clean
  end

  test "an active run of an exclusive flow makes talk exclusive", ctx do
    flow = insert(:flow, board: ctx.board, isolation: :exclusive)
    insert(:run, card: ctx.card, flow_id: flow.id, status: :running)

    assert Runs.talk_isolation(ctx.card) == :exclusive
  end

  test "a terminal run of an exclusive flow does not make talk exclusive", ctx do
    flow = insert(:flow, board: ctx.board, isolation: :exclusive)
    insert(:run, card: ctx.card, flow_id: flow.id, status: :done)

    assert Runs.talk_isolation(ctx.card) == :shared_clean
  end

  test "an active run whose flow no longer loads does not by itself force exclusive", ctx do
    insert(:run, card: ctx.card, flow_id: nil, status: :running)

    assert Runs.talk_isolation(ctx.card) == :shared_clean
  end

  test "a runner on the board holding the card's worktree makes talk exclusive", ctx do
    insert(:runner, board: ctx.board, held: [%{"ref" => ctx.ref, "state" => "running"}])

    assert Runs.talk_isolation(ctx.card) == :exclusive
  end

  test "a retained holding still makes talk exclusive", ctx do
    insert(:runner, board: ctx.board, held: [%{"ref" => ctx.ref, "state" => "retained"}])

    assert Runs.talk_isolation(ctx.card) == :exclusive
  end

  test "a runner on another board holding the same ref text keeps talk shared", ctx do
    insert(:runner, board: insert(:board), held: [%{"ref" => ctx.ref, "state" => "running"}])

    assert Runs.talk_isolation(ctx.card) == :shared_clean
  end

  test "a runner on this board holding a different ref keeps talk shared", ctx do
    insert(:runner, board: ctx.board, held: [%{"ref" => ctx.ref <> "9", "state" => "running"}])

    assert Runs.talk_isolation(ctx.card) == :shared_clean
  end

  describe "Runner.held_refs/1" do
    test "keeps every ref in a holding state, retained included" do
      held = [
        %{"ref" => "A1", "state" => "retained"},
        %{"ref" => "A2", "state" => "talk"},
        %{"ref" => "A3", "state" => "bogus"}
      ]

      assert Runner.held_refs(held) == ["A1", "A2"]
    end

    test "is empty for a non-list" do
      assert Runner.held_refs(nil) == []
    end
  end
end
