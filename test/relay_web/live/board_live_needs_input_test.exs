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

  test "no panel renders for a card that does not need input", %{conn: conn, backlog: backlog, user: user} do
    {:ok, _card} = Cards.create_card(backlog, %{title: "Calm card"})

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

    assert has_element?(view, "#card-drawer")
    refute has_element?(view, "#needs-input-panel")
  end

  test "the reply textarea sits in a full-width wrapper spanning the form",
       %{conn: conn, code: code, user: user} do
    {:ok, card} = Cards.create_card(code, %{title: "Wide reply"})
    {:ok, _blocked} = Cards.request_input(card, "Which bucket?")

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

    assert has_element?(view, "#needs-input-form > div.w-full #needs-input-answer")
  end

  test "a blocked card's drawer shows the amber panel with the latest question and composer",
       %{conn: conn, code: code, user: user} do
    {:ok, card} = Cards.create_card(code, %{title: "Ship exports"})
    {:ok, _blocked} = Cards.request_input(card, "Billing timezone or the viewer's?")

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    assert has_element?(view, "#needs-input-panel", "RELAY AI NEEDS YOUR INPUT")
    assert has_element?(view, "#needs-input-question", "Billing timezone or the viewer's?")
    assert has_element?(view, "#needs-input-waiting", "waiting")

    # the question renders markdown as HTML, not literal text
    {:ok, mdcard} = Cards.create_card(code, %{title: "Markdown ask"})
    {:ok, _} = Cards.request_input(mdcard, "Use **UTC** or the `viewer` tz?")
    {:ok, mdview, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-#{mdcard.ref_number}")
    render_async(mdview)
    assert has_element?(mdview, "#needs-input-question.md strong", "UTC")
    assert has_element?(mdview, "#needs-input-question.md code", "viewer")
    assert has_element?(view, "#needs-input-answer")
    assert has_element?(view, "#needs-input-send", "Send to AI")
    assert has_element?(view, "#card-drawer-activity .timeline-activity-phrase", "asked for input")
  end

  test "re-asking shows the newest question, not the old one", %{conn: conn, code: code, user: user} do
    {:ok, card} = Cards.create_card(code, %{title: "Twice"})
    {:ok, card} = Cards.request_input(card, "First question?")
    {:ok, _card} = Cards.request_input(card, "Second question?")

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    assert has_element?(view, "#needs-input-question", "Second question?")
    refute has_element?(view, "#needs-input-question", "First question?")
  end

  test "answering resumes an AI-stage card to :working, logs, and hides the panel",
       %{conn: conn, board: board, code: code} do
    {:ok, card} = Cards.create_card(code, %{title: "Ship exports"})
    {:ok, _blocked} = Cards.request_input(card, "Which bucket?")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    assert has_element?(view, "#stage-col-#{code.position}-cards .card-needs-input", "needs you")

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

  test "answering a human-stage card returns it to :ready",
       %{conn: conn, board: board, backlog: backlog} do
    {:ok, card} = Cards.create_card(backlog, %{title: "Human next"})
    {:ok, _blocked} = Cards.request_input(card, "Ready to start?")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

    view |> form("#needs-input-form", answer: %{body: "Yes, go"}) |> render_submit()

    refute has_element?(view, "#needs-input-panel")
    assert Cards.get_card_by_ref(board, "RLY-1").status == :ready
  end

  test "a human-blocked card (status control, no question) still gets the composer",
       %{conn: conn, backlog: backlog, user: user} do
    {:ok, card} = Cards.create_card(backlog, %{title: "Manual block"})
    {:ok, _blocked} = Cards.set_status(card, %{status: :needs_input})

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

    assert has_element?(view, "#needs-input-panel")
    refute has_element?(view, "#needs-input-question")
    assert has_element?(view, "#needs-input-answer")
  end

  test "a blank answer is a no-op that keeps the panel", %{conn: conn, board: board, code: code} do
    {:ok, card} = Cards.create_card(code, %{title: "Still blocked"})
    {:ok, _blocked} = Cards.request_input(card, "Which bucket?")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

    view |> form("#needs-input-form", answer: %{body: ""}) |> render_submit()

    assert has_element?(view, "#needs-input-panel")
    assert Cards.get_card_by_ref(board, "RLY-1").status == :needs_input
  end

  test "a request_input from elsewhere pops the panel into an open drawer live (MMF 18)",
       %{conn: conn, code: code, user: user} do
    {:ok, card} = Cards.create_card(code, %{title: "Live block"})

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    refute has_element?(view, "#needs-input-panel")

    {:ok, _blocked} = Cards.request_input(card, "Which region?")

    assert has_element?(view, "#needs-input-panel", "Which region?")
  end

  defp structured_questions do
    [
      %{"prompt" => "Which timezone?", "options" => ["Billing", "Viewer"], "allow_text" => true},
      %{"prompt" => "Any size limit?", "options" => [], "allow_text" => true}
    ]
  end

  test "a structured block renders the stepper: progress, first prompt, option buttons",
       %{conn: conn, code: code, user: user} do
    {:ok, card} = Cards.create_card(code, %{title: "Structured"})
    {:ok, _blocked} = Cards.request_input(card, structured_questions(), :agent)

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    assert has_element?(view, "#needs-input-panel", "RELAY AI NEEDS YOUR INPUT")
    assert has_element?(view, "#needs-input-progress", "Question 1 of 2")
    assert has_element?(view, "#needs-input-question", "Which timezone?")
    assert has_element?(view, "#needs-input-option-0", "Billing")
    assert has_element?(view, "#needs-input-option-1", "Viewer")
    # first step has no Back and shows Next (not Send)
    refute has_element?(view, "#needs-input-back")
    assert has_element?(view, "#needs-input-next")
    refute has_element?(view, "#needs-input-send")
  end

  test "selecting an option then Next advances to Q2, and Back returns preserving the selection",
       %{conn: conn, code: code, user: user} do
    {:ok, card} = Cards.create_card(code, %{title: "Advance"})
    {:ok, _blocked} = Cards.request_input(card, structured_questions(), :agent)

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    view |> element("#needs-input-option-1") |> render_click()
    view |> element("#needs-input-next") |> render_click()

    assert has_element?(view, "#needs-input-progress", "Question 2 of 2")
    assert has_element?(view, "#needs-input-question", "Any size limit?")
    assert has_element?(view, "#needs-input-back")

    view |> element("#needs-input-back") |> render_click()
    assert has_element?(view, "#needs-input-progress", "Question 1 of 2")
    # the previously selected option keeps its selected marker
    assert has_element?(view, "#needs-input-option-1.needs-input-option-selected")
  end

  test "typing a custom answer records it for the step and enables advancing",
       %{conn: conn, code: code, user: user} do
    {:ok, card} = Cards.create_card(code, %{title: "Custom"})
    {:ok, _blocked} = Cards.request_input(card, structured_questions(), :agent)

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    view
    |> form("#needs-input-text-form", answer: %{index: "0", text: "Pacific"})
    |> render_change()

    refute has_element?(view, "#needs-input-next[disabled]")
  end

  test "Send on the last step composes one numbered Q->A comment, resumes :working, hides the panel",
       %{conn: conn, board: board, code: code} do
    {:ok, card} = Cards.create_card(code, %{title: "Send batch"})
    {:ok, _blocked} = Cards.request_input(card, structured_questions(), :agent)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    # Q1: pick an option, advance
    view |> element("#needs-input-option-0") |> render_click()
    view |> element("#needs-input-next") |> render_click()
    # Q2 (free-text only): type an answer, send
    view
    |> form("#needs-input-text-form", answer: %{index: "1", text: "Under 10 MB"})
    |> render_change()

    view |> element("#needs-input-send") |> render_click()

    refute has_element?(view, "#needs-input-panel")

    reloaded = Cards.get_card_by_ref(board, "RLY-1")
    assert reloaded.status == :working
    assert reloaded.blocked_since == nil

    composed = "1. Which timezone? → Billing\n2. Any size limit? → Under 10 MB"
    assert has_element?(view, "#card-drawer-conversation .timeline-comment-body", "Which timezone?")

    comment =
      reloaded
      |> Activity.list_timeline()
      |> Enum.find(&match?(%Comment{body: ^composed}, &1))

    assert comment.actor_type == :user

    # exactly one :input_answered activity
    answered =
      reloaded
      |> Activity.list_timeline()
      |> Enum.filter(&match?(%Schemas.Activity{type: :input_answered}, &1))

    assert length(answered) == 1
  end

  test "the amber Send button keeps the shipped panel's amber fill token",
       %{conn: conn, code: code, user: user} do
    {:ok, card} = Cards.create_card(code, %{title: "Amber"})
    {:ok, _blocked} = Cards.request_input(card, [%{"prompt" => "Only one?"}], :agent)

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    # single-question block: Send is on the first (only) step
    assert has_element?(view, "#needs-input-send[style*='oklch(0.70 0.13 65)']")
  end
end
