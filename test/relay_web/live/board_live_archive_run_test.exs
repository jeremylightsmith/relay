defmodule RelayWeb.BoardLiveArchiveRunTest do
  # RE335 — archiving from the board drawer (the unguarded path) cancels the card's active run
  # through the runs Listener, and the drawer's confirm warns about it only when a run is active.
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Relay.Factory

  alias Relay.Cards
  alias Relay.Repo
  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.Run

  @run_copy "Archive this card? Its active run will be cancelled. You can restore the card from Archived."
  @plain_copy "Archive this card? You can restore it from Archived."

  setup :register_and_log_in_user

  setup %{user: user} do
    FakeDispatcher.register(self())
    start_engine!()

    board = insert(:board, owner: user)
    insert(:membership, board: board, user: user)
    code = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 1)
    flow = insert(:flow, board: board, key: "code", works_in_stage_id: code.id)
    card = insert(:card, stage: code, title: "Parked card")

    run =
      insert(:run,
        card: card,
        flow_id: flow.id,
        flow_key: flow.key,
        status: :parked,
        parked_reason: :needs_input,
        current_node: "implement"
      )

    :ok = Runs.subscribe(board.id)
    %{board: board, code: code, card: card, run: run}
  end

  defp open_overflow(conn, board, card) do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}")
    render_async(view)
    view |> element("#card-drawer-overflow") |> render_click()
    view
  end

  test "a card with an active run gets the run-cancelling confirm copy", ctx do
    view = open_overflow(ctx.conn, ctx.board, ctx.card)

    assert has_element?(view, ~s(#archive-card-button[data-confirm="#{@run_copy}"]))
  end

  test "a card with no active run keeps the plain confirm copy", ctx do
    idle = insert(:card, stage: ctx.code, title: "Idle card")
    view = open_overflow(ctx.conn, ctx.board, idle)

    assert has_element?(view, ~s(#archive-card-button[data-confirm="#{@plain_copy}"]))
  end

  test "a card whose only run already ended keeps the plain confirm copy", ctx do
    done_card = insert(:card, stage: ctx.code, title: "Finished card")
    insert(:run, card: done_card, status: :cancelled, current_node: nil)
    view = open_overflow(ctx.conn, ctx.board, done_card)

    assert has_element?(view, ~s(#archive-card-button[data-confirm="#{@plain_copy}"]))
  end

  test "archiving from the drawer cancels the parked run and logs 'card archived'", ctx do
    view = open_overflow(ctx.conn, ctx.board, ctx.card)
    view |> element("#archive-card-button") |> render_click()

    assert_receive {:run_finished, %Run{id: run_id, status: :cancelled}}
    assert run_id == ctx.run.id
    assert Repo.get!(Run, ctx.run.id).status == :cancelled

    texts =
      Schemas.Card
      |> Repo.get!(ctx.card.id)
      |> Relay.Activity.list_timeline()
      |> Enum.map(& &1.text)

    assert "run cancelled — card archived" in texts
  end
end
