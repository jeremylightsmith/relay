defmodule RelayWeb.BoardLiveBrainstormQuestionsTest do
  @moduledoc """
  RLY-109 — the producer→stepper seam.

  RLY-71 shipped the stepper but every one of its tests fed the LiveView a hand-made
  structured payload, so nothing caught that the sole producer (/brainstorm) still sent one
  big string and the drawer silently fell back to the wall of text. This test starts from
  `test/fixtures/brainstorm_questions.json` — the same bytes bin/test_relay.py pins as the
  POST body — posts it through the real API, and asserts the drawer steps it.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.ApiKeys
  alias Relay.Boards
  alias Relay.Cards

  @fixture "test/fixtures/brainstorm_questions.json"

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: "Brainstorm seam"})
    {:ok, %{token: token}} = ApiKeys.create_key(board, user)
    questions = @fixture |> File.read!() |> Jason.decode!()

    %{board: board, code: code, card: card, token: token, questions: questions}
  end

  defp block_with_fixture(%{board: board, card: card, token: token, questions: questions}) do
    Phoenix.ConnTest.build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> post(~p"/api/cards/#{Cards.ref(board, card)}/needs-input", %{questions: questions})
    |> json_response(200)

    Cards.ref(board, card)
  end

  test "a brainstorm-shaped --questions payload renders as the stepper, not a wall of text",
       %{conn: conn, board: board, questions: questions} = ctx do
    ref = block_with_fixture(ctx)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
    render_async(view)

    assert has_element?(view, "#needs-input-panel", "RELAY AI NEEDS YOUR INPUT")
    assert has_element?(view, "#needs-input-stepper")
    assert has_element?(view, "#needs-input-progress", "Question 1 of #{length(questions)}")
    assert has_element?(view, "#needs-input-option-0")
    # the wall-of-text fallback composer must be absent — that's the whole card
    refute has_element?(view, "#needs-input-form")
  end

  test "the stepper's free-text box is a multi-line textarea, not a single-line input",
       %{conn: conn, board: board} = ctx do
    ref = block_with_fixture(ctx)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
    render_async(view)

    assert has_element?(view, "textarea#needs-input-text")
    refute has_element?(view, "input#needs-input-text")
    assert has_element?(view, ~s|textarea#needs-input-text[rows="3"]|)
    assert has_element?(view, ~s|textarea#needs-input-text[placeholder="Or type your own…"]|)
  end

  test "a typed answer round-trips into the textarea's body",
       %{conn: conn, board: board} = ctx do
    ref = block_with_fixture(ctx)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
    render_async(view)

    view
    |> element("#needs-input-text-form")
    |> render_change(%{"answer" => %{"index" => "0", "text" => "Widen it. Two sentences."}})

    # a textarea's value is its body, not a value= attribute — render it as content or the
    # box comes up empty on every re-render
    assert has_element?(view, "textarea#needs-input-text", "Widen it. Two sentences.")
  end

  test "an open-ended question's textarea reads as the primary prompt, not an afterthought",
       %{conn: conn, board: board, code: code} do
    {:ok, open} = Cards.create_card(code, %{title: "Open ask"})

    {:ok, _blocked} =
      Cards.request_input(
        open,
        [%{"prompt" => "Describe the behavior you want.", "options" => [], "allow_text" => true}],
        :agent
      )

    ref = Cards.ref(board, open)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
    render_async(view)

    refute has_element?(view, "#needs-input-option-0")
    assert has_element?(view, ~s|textarea#needs-input-text[placeholder="Type your answer…"]|)
  end

  # RLY-109 — the card's follow-up ask: "more padding and margin on the questions." This
  # deliberately deviates from docs/designs/Relay Board.dc.html's padding:14px panel; the
  # artboard also predates the stepper entirely, so it is not the authority here. The real
  # wrap/clip geometry is covered by the Playwright suite
  # (test/relay_web/browser/needs_input_stepper_test.exs); these assertions just pin the
  # spacing decision so a future refactor can't quietly undo it.
  test "the questions panel and its stepper have room to breathe",
       %{conn: conn, board: board} = ctx do
    ref = block_with_fixture(ctx)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
    render_async(view)

    # panel: 14px → 20px, per the card comment
    assert has_element?(view, "#needs-input-panel.p-5.gap-4")
    assert has_element?(view, "#needs-input-stepper.gap-4")
    # a long unbroken token (a URL, a module path) must wrap, not widen the panel
    assert has_element?(view, "#needs-input-question.break-words")
    # a wrapped two-line option needs real internal padding or it reads cramped
    assert has_element?(view, "#needs-input-option-0.px-3.py-2")
  end
end
