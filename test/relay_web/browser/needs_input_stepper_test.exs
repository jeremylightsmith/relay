defmodule RelayWeb.Browser.NeedsInputStepperTest do
  @moduledoc """
  Real-browser (Playwright) regression test for RLY-71/RLY-96.

  A real click sends the clicked `<button>`'s intrinsic DOM `.value`
  property alongside any `phx-value-*` attributes. A button with no
  `value` attribute has `.value == ""`, so a `phx-value-value="..."`
  attribute silently loses to the empty intrinsic property once LiveView
  serializes the click. `render_click/1..2` in `Phoenix.LiveViewTest`
  reads `phx-value-*` straight off the rendered HTML and never
  reproduces that collision, so this bug is invisible to LiveView tests —
  only a real click, round-tripped through an actual browser, catches it.

  RE323 — one action per question: a real option click sends a single-question batch, and
  ⌘/Ctrl+Enter in `#needs-input-text` goes through `SubmitOnCmdEnter` → `form.requestSubmit()`
  → `phx-submit="answer_commit"`. That hook path, and the textarea resetting when a focused box
  moves to another question, only exist in a real browser. On the submit path LiveView's form
  lock/unlock already refreshes the focused box; `SubmitOnCmdEnter.updated()` is what resets it
  when the step changes through any other patch — the "not a submit" test is the one that fails
  without it.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright

  test "clicking a multiple-choice option sends the chosen option's text in one action", %{conn: conn} do
    board = dev_board()
    questions = [%{"prompt" => "Which timezone?", "options" => ["Billing", "Viewer"], "allow_text" => false}]
    card = blocked_card(board, "Stepper smoke", questions)

    conn
    |> open_drawer(board, card)
    |> click("#needs-input-option-0")
    |> refute_has("#needs-input-panel")
    |> reopen_drawer(board, card)
    |> assert_has("#card-drawer-conversation .timeline-comment-body", "Billing")
  end

  # A real agent's options are whole sentences, not one-word labels. daisyUI's
  # `.btn` is a fixed-height (`height: var(--size)`) nowrap flex row, so a long
  # option clipped instead of wrapping. Geometry is the only honest assertion
  # here: the classes could look right and still overflow.
  test "a long option wraps onto multiple lines instead of clipping", %{conn: conn} do
    board = dev_board()

    long =
      "RLY-84 owns only the residual that RLY-81 does not cover — the onboarding " <>
        "sequencing and the decline path — and the AUTH-03 screen itself stays RLY-81's"

    questions = [%{"prompt" => "Which scoping?", "options" => [long, "Something else"], "allow_text" => false}]

    card = blocked_card(board, "Long option", questions)

    conn
    |> open_drawer(board, card)
    # assert_has waits for the option to actually be in the DOM; `evaluate` below
    # does not auto-wait, and would otherwise read a null element.
    |> assert_has("#needs-input-option-0")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, box} =
        Frame.evaluate(frame_id,
          expression: """
          (() => {
            const b = document.querySelector('#needs-input-option-0');
            return {
              clipped: b.scrollHeight - b.clientHeight,
              height: b.clientHeight,
              lines: Math.round(b.scrollHeight / parseFloat(getComputedStyle(b).lineHeight)),
            };
          })()
          """,
          timeout: 2_000
        )

      # Nothing is cut off…
      assert box["clipped"] <= 1,
             "the option clips #{box["clipped"]}px of its text (height #{box["height"]}px)"

      # …because it actually grew to more than one line, rather than staying a
      # single fixed-height row that merely hides the overflow.
      assert box["lines"] > 1, "the option rendered on one line (height #{box["height"]}px)"
    end)
  end

  test "⌘+Enter in the text field sends a typed answer (AC3)", %{conn: conn} do
    board = dev_board()
    questions = [%{"prompt" => "Which timezone?", "options" => [], "allow_text" => true}]
    card = blocked_card(board, "Cmd enter", questions)

    conn
    |> open_drawer(board, card)
    |> assert_has("#needs-input-text")
    |> type_and_press("use the billing timezone", "Meta+Enter")
    |> refute_has("#needs-input-panel")
    |> reopen_drawer(board, card)
    |> assert_has("#card-drawer-conversation .timeline-comment-body", "use the billing timezone")
  end

  test "⌘+Enter on a non-final question advances with an empty box; Ctrl+Enter on the last sends both (AC4)",
       %{conn: conn} do
    board = dev_board()

    questions = [
      %{"prompt" => "Which timezone?", "options" => [], "allow_text" => true},
      %{"prompt" => "Any size limit?", "options" => [], "allow_text" => true}
    ]

    card = blocked_card(board, "Two typed", questions)

    conn
    |> open_drawer(board, card)
    |> assert_has("#needs-input-text")
    |> type_and_press("Pacific", "Meta+Enter")
    |> assert_has("#needs-input-progress", text: "Question 2 of 2")
    |> refute_has("#card-drawer-conversation .timeline-comment-body", text: "Pacific")
    |> unwrap(fn %{frame_id: frame_id} ->
      # the focused box must not carry question 1's answer into question 2 (on this submit path
      # LiveView's form unlock already guarantees it; the next test covers the hook's own reset)
      {:ok, value} = Frame.input_value(frame_id, selector: "#needs-input-text", timeout: 2_000)
      assert value == "", "question 2's box still holds #{inspect(value)}"
    end)
    |> type_and_press("Under 10 MB", "Control+Enter")
    |> refute_has("#needs-input-panel")
    |> reopen_drawer(board, card)
    |> assert_has("#card-drawer-conversation .timeline-comment-body", text: "Which timezone? → Pacific")
    |> assert_has("#card-drawer-conversation .timeline-comment-body", text: "Any size limit? → Under 10 MB")
  end

  # AC4's box check above goes through phx-submit, and LiveView's form lock already hands the
  # focused textarea the server's value when the ack unlocks the form — so it passes with or
  # without SubmitOnCmdEnter.updated(). This is the path only the hook covers: the step changes
  # through a plain event patch while the box keeps focus (a programmatic `.click()` does not
  # move focus), where LiveView's focused-input rule keeps the stale text. Without the hook's
  # reset the box still reads "Under 10 MB" on question 1.
  test "a step change that is not a submit resets the still-focused box to that step's answer",
       %{conn: conn} do
    board = dev_board()

    questions = [
      %{"prompt" => "Which timezone?", "options" => [], "allow_text" => true},
      %{"prompt" => "Any size limit?", "options" => [], "allow_text" => true}
    ]

    card = blocked_card(board, "Focused back", questions)

    conn
    |> open_drawer(board, card)
    |> assert_has("#needs-input-text")
    |> type_and_press("Pacific", "Meta+Enter")
    |> assert_has("#needs-input-progress", text: "Question 2 of 2")
    |> type_only("Under 10 MB")
    # the phx-change round-trip has landed once the server echoes the text back
    |> assert_has(~s|#needs-input-text[data-value="Under 10 MB"]|)
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} =
        Frame.evaluate(frame_id,
          expression: "document.querySelector('#needs-input-back').click()",
          timeout: 2_000
        )
    end)
    |> assert_has("#needs-input-progress", text: "Question 1 of 2")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, focused} =
        Frame.evaluate(frame_id, expression: "document.activeElement && document.activeElement.id", timeout: 2_000)

      assert focused == "needs-input-text", "the box lost focus (#{inspect(focused)}), so this proves nothing"

      {:ok, value} = Frame.input_value(frame_id, selector: "#needs-input-text", timeout: 2_000)
      assert value == "Pacific", "question 1's box holds #{inspect(value)} instead of its own answer"
    end)
  end

  defp dev_board do
    user = Accounts.ensure_dev_user!()
    Boards.get_or_create_default_board(user)
  end

  defp blocked_card(board, title, questions) do
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: title})
    {:ok, _blocked} = Cards.request_input(card, questions, :agent)
    card
  end

  # Waits for the connected socket on the board page itself: a keypress that lands before the
  # hook mounts is simply lost (see typing_key_guard_test.exs).
  defp open_drawer(conn, board, card) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}?card=#{board.key}#{card.ref_number}")
    |> assert_has("#needs-input-panel")
    |> assert_has("body .phx-connected")
  end

  # Sending closes the drawer on the board route (RLY-115's close_drawer_after_action), so the
  # posted answer is read back by reopening the card; the card is no longer blocked, so the
  # needs-input panel must stay gone.
  defp reopen_drawer(session, board, card) do
    session
    |> visit("/board/#{board.slug}?card=#{board.key}#{card.ref_number}")
    |> assert_has("#card-drawer-conversation")
    |> refute_has("#needs-input-panel")
  end

  defp type_only(session, text) do
    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.type(frame_id, selector: "#needs-input-text", text: text, timeout: 2_000)
    end)
  end

  defp type_and_press(session, text, key) do
    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.type(frame_id, selector: "#needs-input-text", text: text, timeout: 2_000)
      {:ok, _} = Frame.press(frame_id, selector: "#needs-input-text", key: key, timeout: 2_000)
    end)
  end
end
