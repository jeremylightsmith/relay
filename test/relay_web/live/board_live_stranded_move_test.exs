defmodule RelayWeb.BoardLiveStrandedMoveTest do
  # async: false — cancel_run/1 (exercised by the confirm test) touches the singleton
  # Relay.Runs.Registry, same as Relay.RunsTest / NodeJobControllerTest.
  use RelayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Relay.Factory

  alias Relay.Cards
  alias Relay.Repo
  alias Relay.Runs.FakeDispatcher

  setup :register_and_log_in_user

  setup %{user: user} do
    FakeDispatcher.register(self())
    start_supervised!(Relay.Runs.Supervisor)

    board = insert(:board, owner: user)
    insert(:membership, board: board, user: user)
    code = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 1)
    done = insert(:stage, board: board, name: "Done", type: :done, position: 2)
    flow = insert(:flow, board: board, key: "code", works_in_stage_id: code.id)
    card = insert(:card, stage: code, title: "Live card")
    run = insert(:run, card: card, flow_id: flow.id, flow_key: flow.key, status: :parked, current_node: "implement")
    %{board: board, code: code, done: done, card: card, run: run}
  end

  defp drop(view, board, card, stage) do
    render_hook(view, "move_card", %{
      "ref" => Cards.ref(board, card),
      "stage_id" => to_string(stage.id),
      "index" => 0
    })
  end

  test "dropping a live-run card out of its lane opens the modal and does not move", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")
    drop(view, ctx.board, ctx.card, ctx.done)

    assert has_element?(view, "#stranded-move-modal")
    assert has_element?(view, "#stranded-move-modal", "implement")
    assert has_element?(view, "#stranded-move-modal", "code")
    assert Repo.get!(Schemas.Card, ctx.card.id).stage_id == ctx.code.id
  end

  test "declining leaves the card and run untouched", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")
    drop(view, ctx.board, ctx.card, ctx.done)

    view |> element("#stranded-move-cancel") |> render_click()

    refute has_element?(view, "#stranded-move-modal")
    assert Repo.get!(Schemas.Card, ctx.card.id).stage_id == ctx.code.id
    assert Repo.get!(Schemas.Run, ctx.run.id).status == :parked
  end

  test "confirming moves the card and cancels the run", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")
    drop(view, ctx.board, ctx.card, ctx.done)

    view |> element("#stranded-move-confirm") |> render_click()

    refute has_element?(view, "#stranded-move-modal")
    assert Repo.get!(Schemas.Card, ctx.card.id).stage_id == ctx.done.id
    assert Repo.get!(Schemas.Run, ctx.run.id).status == :cancelled
  end

  test "an ordinary move of a card with no run is not interrupted", ctx do
    plain = insert(:card, stage: ctx.code, title: "No run")
    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")
    drop(view, ctx.board, plain, ctx.done)

    refute has_element?(view, "#stranded-move-modal")
    assert Repo.get!(Schemas.Card, plain.id).stage_id == ctx.done.id
  end
end
