defmodule RelayWeb.BoardLiveNeedsInputTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias Schemas.Comment

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
    code = Enum.find(board.stages, &(&1.name == "Code"))
    %{board: board, backlog: backlog, code: code}
  end

  test "no panel renders for a card that does not need input", %{conn: conn, backlog: backlog} do
    {:ok, _card} = Cards.create_card(backlog, %{title: "Calm card"})

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    assert has_element?(view, "#card-drawer")
    refute has_element?(view, "#needs-input-panel")
  end

  test "a blocked card's drawer shows the amber panel with the latest question and composer",
       %{conn: conn, code: code} do
    {:ok, card} = Cards.create_card(code, %{title: "Ship exports"})
    {:ok, _blocked} = Cards.request_input(card, "Billing timezone or the viewer's?")

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    assert has_element?(view, "#needs-input-panel", "RELAY AI NEEDS YOUR INPUT")
    assert has_element?(view, "#needs-input-question", "Billing timezone or the viewer's?")
    assert has_element?(view, "#needs-input-waiting", "waiting")

    # the question renders markdown as HTML, not literal text
    {:ok, mdcard} = Cards.create_card(code, %{title: "Markdown ask"})
    {:ok, _} = Cards.request_input(mdcard, "Use **UTC** or the `viewer` tz?")
    {:ok, mdview, _html} = live(conn, ~p"/board?card=RLY-#{mdcard.ref_number}")
    assert has_element?(mdview, "#needs-input-question.md strong", "UTC")
    assert has_element?(mdview, "#needs-input-question.md code", "viewer")
    assert has_element?(view, "#needs-input-answer")
    assert has_element?(view, "#needs-input-send", "Send to AI")
    assert has_element?(view, "#card-drawer-activity .timeline-activity-phrase", "asked for input")
  end

  test "re-asking shows the newest question, not the old one", %{conn: conn, code: code} do
    {:ok, card} = Cards.create_card(code, %{title: "Twice"})
    {:ok, card} = Cards.request_input(card, "First question?")
    {:ok, _card} = Cards.request_input(card, "Second question?")

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    assert has_element?(view, "#needs-input-question", "Second question?")
    refute has_element?(view, "#needs-input-question", "First question?")
  end

  test "answering resumes an AI-stage card to :working, logs, and hides the panel",
       %{conn: conn, board: board, code: code} do
    {:ok, card} = Cards.create_card(code, %{title: "Ship exports"})
    {:ok, _blocked} = Cards.request_input(card, "Which bucket?")

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")
    assert has_element?(view, "#stage-col-#{code.position}-cards .card-needs-input", "NEEDS INPUT")

    view
    |> form("#needs-input-form", answer: %{body: "The relay-exports bucket"})
    |> render_submit()

    refute has_element?(view, "#needs-input-panel")
    assert has_element?(view, "#card-drawer-conversation .timeline-comment-body", "The relay-exports bucket")
    assert has_element?(view, "#card-drawer-activity .timeline-activity-phrase", "answered the question")
    refute has_element?(view, "#stage-col-#{code.position}-cards .card-needs-input")

    reloaded = Cards.get_card_by_ref(board, "RLY-1")
    assert reloaded.status == :working
    assert reloaded.blocked_since == nil

    answer =
      reloaded
      |> Activity.list_timeline()
      |> Enum.find(&match?(%Comment{body: "The relay-exports bucket"}, &1))

    assert answer.actor_type == :user
  end

  test "answering a human-stage card returns it to :queued",
       %{conn: conn, board: board, backlog: backlog} do
    {:ok, card} = Cards.create_card(backlog, %{title: "Human next"})
    {:ok, _blocked} = Cards.request_input(card, "Ready to start?")

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view |> form("#needs-input-form", answer: %{body: "Yes, go"}) |> render_submit()

    refute has_element?(view, "#needs-input-panel")
    assert Cards.get_card_by_ref(board, "RLY-1").status == :queued
  end

  test "a human-blocked card (status control, no question) still gets the composer",
       %{conn: conn, backlog: backlog} do
    {:ok, card} = Cards.create_card(backlog, %{title: "Manual block"})
    {:ok, _blocked} = Cards.set_status(card, %{status: :needs_input})

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    assert has_element?(view, "#needs-input-panel")
    refute has_element?(view, "#needs-input-question")
    assert has_element?(view, "#needs-input-answer")
  end

  test "a blank answer is a no-op that keeps the panel", %{conn: conn, board: board, code: code} do
    {:ok, card} = Cards.create_card(code, %{title: "Still blocked"})
    {:ok, _blocked} = Cards.request_input(card, "Which bucket?")

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view |> form("#needs-input-form", answer: %{body: ""}) |> render_submit()

    assert has_element?(view, "#needs-input-panel")
    assert Cards.get_card_by_ref(board, "RLY-1").status == :needs_input
  end

  test "a request_input from elsewhere pops the panel into an open drawer live (MMF 18)",
       %{conn: conn, code: code} do
    {:ok, card} = Cards.create_card(code, %{title: "Live block"})

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")
    refute has_element?(view, "#needs-input-panel")

    {:ok, _blocked} = Cards.request_input(card, "Which region?")

    assert has_element?(view, "#needs-input-panel", "Which region?")
  end
end
