defmodule Hamaca.CardsStrandedMoveTest do
  use Hamaca.DataCase, async: true

  import Hamaca.Factory

  alias Hamaca.Cards

  setup do
    board = insert(:board)
    queue = insert(:stage, board: board, name: "Queue", type: :queue, position: 1)
    code = insert(:stage, board: board, name: "Code", type: :work, position: 2)
    done = insert(:stage, board: board, name: "Done", type: :done, position: 3)
    flow = insert(:flow, board: board, key: "code", stage_id: code.id)
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

    test "nil for a within-lane reorder (destination == the flow's stage)", ctx do
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

  describe "stranded_runs/2" do
    test "maps each card with a stranding run to that run, leaving run-less cards out", ctx do
      a = insert(:card, stage: ctx.code)
      b = insert(:card, stage: ctx.code)
      c = insert(:card, stage: ctx.code)
      run_a = with_run(a, ctx.flow, :running)
      run_b = with_run(b, ctx.flow, :parked)

      stranded = Cards.stranded_runs([a, b, c], ctx.done)

      assert stranded |> Map.keys() |> Enum.sort() == Enum.sort([a.id, b.id])
      assert stranded[a.id].id == run_a.id
      assert stranded[b.id].id == run_b.id
    end

    test "is empty for a move into the run's own lane", ctx do
      a = insert(:card, stage: ctx.code)
      with_run(a, ctx.flow, :running)

      assert Cards.stranded_runs([a], ctx.code) == %{}
    end

    test "is empty for an empty card list", ctx do
      assert Cards.stranded_runs([], ctx.done) == %{}
    end

    test "is empty for a card whose run is terminal", ctx do
      a = insert(:card, stage: ctx.code)
      # `:done` is the successful terminal status (Run.terminal_statuses/0).
      with_run(a, ctx.flow, :done)

      assert Cards.stranded_runs([a], ctx.done) == %{}
    end

    test "batches the whole list into one query", ctx do
      cards = for _ <- 1..3, do: insert(:card, stage: ctx.code)
      Enum.each(cards, &with_run(&1, ctx.flow, :parked))

      test_pid = self()
      handler_id = "stranded-runs-#{inspect(make_ref())}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:hamaca, :repo, :query],
          fn _event, _measurements, metadata, _config ->
            if self() == test_pid, do: send(test_pid, {:query, metadata.source})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert map_size(Cards.stranded_runs(cards, ctx.done)) == 3
      assert_received {:query, "runs"}
      refute_received {:query, _}
    end
  end

  describe "move_card/4 stranding guard" do
    test "refuses a stranding move and does not move the card", ctx do
      card = insert(:card, stage: ctx.code)
      with_run(card, ctx.flow, :parked)
      assert {:error, :would_strand_run} = Cards.move_card(card, ctx.done, 0, :agent)
      assert Hamaca.Repo.get!(Schemas.Card, card.id).stage_id == ctx.code.id
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
