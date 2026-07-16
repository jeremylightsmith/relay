defmodule RelayWeb.BoardHealthTest do
  use RelayWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Repo

  setup :register_and_log_in_user

  # Build the board the way the app does — a real default board with real stages. The
  # card lives in Code: a real ai_enabled stage, since the strip only renders in one
  # (2026-07-16 rejection).
  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: "Migrate 40 blog posts"})
    %{board: board, stage: code, card: card, ref: Cards.ref(board, card)}
  end

  defp claim_ai(card) do
    {:ok, card} = Cards.assign_ai(card)
    {:ok, card} = Cards.set_status(card, %{status: :working})
    card
  end

  # Backdate every scrap of this card's evidence so it reads quiet.
  defp go_quiet(card) do
    quiet = DateTime.utc_now() |> DateTime.add(-20 * 60, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(a in Schemas.Activity, where: a.card_id == ^card.id), set: [inserted_at: quiet])
    quiet
  end

  test "a live card shows the violet strip in place of the working label", %{
    conn: conn,
    board: board,
    card: card,
    ref: ref
  } do
    claim_ai(card)
    insert(:activity, card: card, type: :action, text: "uploaded 24/40 posts")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    assert has_element?(view, "#card-#{ref}-log-strip[data-health='live']")
    assert render(view) =~ "uploaded 24/40 posts"
    refute has_element?(view, "[data-ref='#{ref}'] .card-status")
  end

  test "a card with no active agent renders no strip and is unchanged", %{conn: conn, board: board, card: card, ref: ref} do
    {:ok, _card} = Cards.set_status(card, %{status: :working})
    insert(:activity, card: card, type: :action, text: "orphan line")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    refute has_element?(view, "#card-#{ref}-log-strip")
    assert has_element?(view, "[data-ref='#{ref}'] .card-status")
  end

  test "the 30s tick flips a quiet card live -> stale with no other event", %{
    conn: conn,
    board: board,
    card: card,
    ref: ref
  } do
    card = claim_ai(card)
    insert(:activity, card: card, type: :action, text: "reindexing 12k documents")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    assert has_element?(view, "#card-#{ref}-log-strip[data-health='live']")

    # Nothing broadcasts when a card GOES QUIET — that is the whole point of the tick.
    go_quiet(card)
    send(view.pid, :health_tick)

    assert has_element?(view, "#card-#{ref}-log-strip[data-health='stale']")
    assert has_element?(view, "[data-ref='#{ref}'].border-l-warning")
  end

  test "a fresh heartbeat alone keeps a quiet card live across a tick", %{conn: conn, board: board, card: card, ref: ref} do
    card = claim_ai(card)
    go_quiet(card)

    Repo.update_all(from(c in Schemas.Card, where: c.id == ^card.id),
      set: [agent_heartbeat_at: DateTime.truncate(DateTime.utc_now(), :second)]
    )

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    send(view.pid, :health_tick)

    assert has_element?(view, "#card-#{ref}-log-strip[data-health='live']")
  end

  test "a failure flips the card rose, with no Retry", %{conn: conn, board: board, card: card, ref: ref} do
    card = claim_ai(card)
    insert(:activity, card: card, type: :failure, text: "agent stopped")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    assert has_element?(view, "#card-#{ref}-log-strip[data-health='stopped']")
    assert has_element?(view, "[data-ref='#{ref}'].border-l-error")
    refute render(view) =~ "Retry"
  end

  test "a card_log_appended batch updates the strip in place", %{conn: conn, board: board, card: card, ref: ref} do
    card = claim_ai(card)
    insert(:activity, card: card, type: :action, text: "old line")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    entry = insert(:activity, card: card, type: :action, text: "🔧 Edit lib/relay/cards.ex")
    send(view.pid, {:card_log_appended, card.id, [entry]})

    assert render(view) =~ "🔧 Edit lib/relay/cards.ex"
    assert has_element?(view, "#card-#{ref}-log-strip[data-health='live']")
  end

  test "an AI card with fresh logs in a non-AI column shows no strip", %{conn: conn, board: board} do
    backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
    {:ok, card} = Cards.create_card(backlog, %{title: "Queued research"})
    card = claim_ai(card)
    insert(:activity, card: card, type: :action, text: "ghost line")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    refute has_element?(view, "#card-#{Cards.ref(board, card)}-log-strip")
  end

  test "moving a live card out of an AI column drops the strip immediately, before any tick", %{
    conn: conn,
    board: board,
    card: card,
    ref: ref
  } do
    card = claim_ai(card)
    insert(:activity, card: card, type: :action, text: "uploaded 24/40 posts")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    assert has_element?(view, "#card-#{ref}-log-strip[data-health='live']")

    review = Enum.find(board.stages, &(&1.name == "Review"))
    {:ok, _moved} = Cards.move_card(card, review, 0)

    refute has_element?(view, "#card-#{ref}-log-strip")
  end

  test "releasing the AI owner drops the strip without waiting for the tick", %{
    conn: conn,
    board: board,
    card: card,
    ref: ref
  } do
    card = claim_ai(card)
    insert(:activity, card: card, type: :action, text: "uploaded 24/40 posts")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    assert has_element?(view, "#card-#{ref}-log-strip[data-health='live']")

    {:ok, _released} = Cards.set_owners(card, [])

    refute has_element?(view, "#card-#{ref}-log-strip")
  end
end
