defmodule Relay.CardsStrandedMoveTest do
  use Relay.DataCase, async: true

  import Relay.Factory

  alias Relay.Cards

  setup do
    board = insert(:board)
    queue = insert(:stage, board: board, name: "Queue", type: :queue, position: 1)
    code = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 2)
    done = insert(:stage, board: board, name: "Done", type: :done, position: 3)
    flow = insert(:flow, board: board, key: "code", works_in_stage_id: code.id)
    {:ok, board: board, queue: queue, code: code, done: done, flow: flow}
  end

  defp with_run(card, flow, status) do
    insert(:run, card: card, flow_id: flow.id, flow_key: flow.key, status: status)
  end

  describe "stranded_run/2" do
    test "returns the active run for a move out of the work lane", ctx do
      card = insert(:card, stage: ctx.code)
      run = with_run(card, ctx.flow, :parked)
      assert %Schemas.Run{id: id} = Cards.stranded_run(card, ctx.done)
      assert id == run.id
    end

    test "nil for a within-lane reorder (destination == works_in_stage)", ctx do
      card = insert(:card, stage: ctx.code)
      with_run(card, ctx.flow, :running)
      assert Cards.stranded_run(card, ctx.code) == nil
    end

    test "nil when the destination IS the run's work lane (engine pull is transparent)", ctx do
      # card sits in its pull stage with an active run; moving INTO the lane never strands
      card = insert(:card, stage: ctx.queue)
      with_run(card, ctx.flow, :running)
      assert Cards.stranded_run(card, ctx.code) == nil
    end

    test "nil for a card with no active run", ctx do
      card = insert(:card, stage: ctx.code)
      assert Cards.stranded_run(card, ctx.done) == nil
    end

    test "nil for a terminal run", ctx do
      card = insert(:card, stage: ctx.code)
      with_run(card, ctx.flow, :cancelled)
      assert Cards.stranded_run(card, ctx.done) == nil
    end
  end

  describe "move_card/4 stranding guard" do
    test "refuses a stranding move and does not move the card", ctx do
      card = insert(:card, stage: ctx.code)
      with_run(card, ctx.flow, :parked)
      assert {:error, :would_strand_run} = Cards.move_card(card, ctx.done, 0, :agent)
      assert Relay.Repo.get!(Schemas.Card, card.id).stage_id == ctx.code.id
    end

    test "an into-lane move with an active run still succeeds (engine pull regression)", ctx do
      card = insert(:card, stage: ctx.queue)
      with_run(card, ctx.flow, :running)
      assert {:ok, moved} = Cards.move_card(card, ctx.code, 0, :agent)
      assert moved.stage_id == ctx.code.id
    end

    test "a normal move of a card with no run is unaffected", ctx do
      card = insert(:card, stage: ctx.code)
      assert {:ok, moved} = Cards.move_card(card, ctx.done, 0, :agent)
      assert moved.stage_id == ctx.done.id
    end
  end
end
