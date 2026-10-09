defmodule RelayWeb.BoardLiveFlowsReloadTest do
  # RE429 — a flow's pickup is derived from board order at read time, so an open board must
  # re-read `@flows` on `{:stages_changed, _}` or the "Queued for <flow>" chip goes stale.
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Flows

  setup :register_and_log_in_user

  test "the drawer's queued chip follows a stage inserted before the flow's stage", %{
    conn: conn,
    user: user
  } do
    board = Boards.get_or_create_default_board(user)
    next_up = Enum.find(board.stages, &(&1.name == "Next up"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    {:ok, _flow} = board |> Flows.get_flow!("spec") |> Flows.enable_flow()
    {:ok, card} = Cards.create_card(next_up, %{title: "Waiting for spec"})

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}")
    render_async(view)

    ref = Cards.ref(board, card)

    # Spec pulls from the stage right before it — Next up — so the card is queued for it, on
    # both the board card's face and the drawer.
    assert has_element?(view, "#card-#{ref}-run-face")
    assert has_element?(view, "#card-drawer-run-face")

    # A new stage between Next up and Spec becomes Spec's pickup; Next up no longer feeds it.
    {:ok, _triage} = Boards.create_stage(board, %{name: "Triage", before: spec})
    render(view)

    refute has_element?(view, "#card-#{ref}-run-face")
    refute has_element?(view, "#card-drawer-run-face")
  end
end
