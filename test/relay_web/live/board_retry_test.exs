defmodule RelayWeb.BoardRetryTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: "Generate the API client"})
    {:ok, card} = Cards.assign_ai(card)
    {:ok, card} = Cards.set_status(card, %{status: :working})
    insert(:activity, card: card, type: :failure, text: "agent stopped")
    %{board: board, card: card, ref: Cards.ref(board, card)}
  end

  test "the stopped strip shows Retry, and clicking it re-arms the card in place", %{
    conn: conn,
    board: board,
    card: card,
    ref: ref
  } do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    assert has_element?(view, "#card-#{ref}-log-strip[data-health='stopped']")
    assert has_element?(view, "#card-#{ref}-retry")

    view |> element("#card-#{ref}-retry") |> render_click()

    reloaded = Cards.get_card(board, card.id)
    assert reloaded.status == :working
    [newest | _rest] = Activity.list_activity(reloaded)
    assert newest.type == :action
    assert newest.text == "retry requested"
    assert newest.actor_type == :user

    # The retry broadcast restreams the card: the strip leaves :stopped without a reload.
    assert has_element?(view, "#card-#{ref}-log-strip[data-health='live']")
    refute has_element?(view, "#card-#{ref}-retry")
  end
end
