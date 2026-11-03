defmodule Hamaca.RunsBulkMoveTest do
  use Hamaca.DataCase, async: true

  import Hamaca.Factory

  alias Hamaca.Cards
  alias Hamaca.Repo
  alias Hamaca.Runs
  alias Hamaca.Runs.FakeDispatcher
  alias Schemas.Activity
  alias Schemas.Card

  setup do
    user = insert(:user)
    board = insert(:board, owner: user)
    queue = insert(:stage, board: board, name: "Queue", type: :queue, position: 1)
    code = insert(:stage, board: board, name: "Code", type: :work, position: 2)
    done = insert(:stage, board: board, name: "Done", type: :done, position: 3)
    flow = insert(:flow, board: board, key: "code", stage_id: code.id)
    {:ok, user: user, board: board, queue: queue, code: code, done: done, flow: flow}
  end

  defp with_run(card, flow, status) do
    insert(:run, card: card, flow_id: flow.id, flow_key: flow.key, status: status, current_node: "implement")
  end

  defp ids(cards), do: Enum.map(cards, & &1.id)

  defp stage_order(stage) do
    Card
    |> where([c], c.stage_id == ^stage.id)
    |> order_by([c], asc: c.position)
    |> Repo.all()
    |> ids()
  end

  test "moves every card to the bottom of the target stage, in the order given, credited to the actor",
       ctx do
    existing = insert(:card, stage: ctx.done)
    [x, y, z] = for _ <- 1..3, do: insert(:card, stage: ctx.queue)

    assert %{moved: moved, skipped: []} =
             Runs.bulk_move_cards([x, y, z], ctx.done, {:user, ctx.user.id}, cancel_runs: false)

    assert length(moved) == 3
    assert Enum.all?(moved, &(&1.stage_id == ctx.done.id))
    assert stage_order(ctx.done) == [existing.id, x.id, y.id, z.id]

    for card <- [x, y, z] do
      assert [%Activity{actor_type: :user, user_id: user_id}] =
               Repo.all(from a in Activity, where: a.card_id == ^card.id and a.type == :moved)

      assert user_id == ctx.user.id
    end
  end

  test "a card already in the target stage is neither moved nor skipped", ctx do
    x = insert(:card, stage: ctx.queue)
    # A real stage is contiguous 1..n; X's append renumbers Done, which must leave Y where it is.
    y = insert(:card, stage: ctx.done, position: 1)

    assert %{moved: moved, skipped: []} = Runs.bulk_move_cards([x, y], ctx.done, :agent, cancel_runs: false)

    assert ids(moved) == [x.id]
    assert Repo.get!(Card, y.id).position == 1
  end

  test "without cancel_runs a card whose move would strand a live run is skipped and left alone", ctx do
    x = insert(:card, stage: ctx.queue)
    y = insert(:card, stage: ctx.code)
    run = with_run(y, ctx.flow, :parked)

    assert %{moved: moved, skipped: skipped} = Runs.bulk_move_cards([x, y], ctx.done, :agent, cancel_runs: false)

    assert ids(moved) == [x.id]
    assert ids(skipped) == [y.id]
    assert Repo.get!(Card, y.id).stage_id == ctx.code.id
    assert Repo.get!(Schemas.Run, run.id).status == :parked
  end

  describe "with cancel_runs: true" do
    setup do
      FakeDispatcher.register(self())
      start_engine!()
      :ok
    end

    test "cancels the stranding run, credited to the actor, then moves the card", ctx do
      x = insert(:card, stage: ctx.queue)
      y = insert(:card, stage: ctx.code)
      run = with_run(y, ctx.flow, :parked)

      assert %{moved: moved, skipped: []} =
               Runs.bulk_move_cards([x, y], ctx.done, {:user, ctx.user.id}, cancel_runs: true)

      assert ids(moved) == [x.id, y.id]
      assert Repo.get!(Card, y.id).stage_id == ctx.done.id
      assert Repo.get!(Schemas.Run, run.id).status == :cancelled

      assert [%Activity{actor_type: :user, user_id: user_id}] =
               Repo.all(
                 from a in Activity,
                   where: a.card_id == ^y.id and a.type == :action and a.text == "run cancelled"
               )

      assert user_id == ctx.user.id
    end
  end

  test "a card archived after it was loaded is skipped and not moved", ctx do
    x = insert(:card, stage: ctx.queue)
    y = insert(:card, stage: ctx.queue)
    Cards.archive_card(y)

    assert %{moved: moved, skipped: skipped} = Runs.bulk_move_cards([x, y], ctx.done, :agent, cancel_runs: false)

    assert ids(moved) == [x.id]
    assert ids(skipped) == [y.id]
    assert Repo.get!(Card, y.id).stage_id == ctx.queue.id
  end

  test "a card deleted after it was loaded is skipped without raising", ctx do
    x = insert(:card, stage: ctx.queue)
    y = insert(:card, stage: ctx.queue)
    Repo.delete!(y)

    assert %{moved: moved, skipped: skipped} = Runs.bulk_move_cards([x, y], ctx.done, :agent, cancel_runs: false)

    assert ids(moved) == [x.id]
    assert ids(skipped) == [y.id]
  end

  test "a card on another board is skipped and not moved", ctx do
    x = insert(:card, stage: ctx.queue)
    foreign = insert(:card, stage: insert(:stage, board: insert(:board)))

    assert %{moved: moved, skipped: skipped} =
             Runs.bulk_move_cards([x, foreign], ctx.done, :agent, cancel_runs: false)

    assert ids(moved) == [x.id]
    assert ids(skipped) == [foreign.id]
    assert Repo.get!(Card, foreign.id).stage_id == foreign.stage_id
  end
end
