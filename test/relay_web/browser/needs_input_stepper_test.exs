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
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright

  test "picking a multiple-choice option and sending records the chosen option's text", %{conn: conn} do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: "Stepper smoke"})

    questions = [
      %{"prompt" => "Which timezone?", "options" => ["Billing", "Viewer"], "allow_text" => false}
    ]

    {:ok, _blocked} = Cards.request_input(card, questions, :agent)

    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}?card=#{board.key}#{card.ref_number}")
    |> assert_has("#needs-input-panel")
    |> click("#needs-input-option-0")
    # the picked option must get the amber selected marker after a real click
    |> assert_has("#needs-input-option-0.needs-input-option-selected")
    |> click("#needs-input-send")
    |> assert_has("#card-drawer-conversation .timeline-comment-body", "Billing")
  end

  # A real agent's options are whole sentences, not one-word labels. daisyUI's
  # `.btn` is a fixed-height (`height: var(--size)`) nowrap flex row, so a long
  # option clipped instead of wrapping. Geometry is the only honest assertion
  # here: the classes could look right and still overflow.
  test "a long option wraps onto multiple lines instead of clipping", %{conn: conn} do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: "Long option"})

    long =
      "RLY-84 owns only the residual that RLY-81 does not cover — the onboarding " <>
        "sequencing and the decline path — and the AUTH-03 screen itself stays RLY-81's"

    questions = [%{"prompt" => "Which scoping?", "options" => [long, "Something else"], "allow_text" => false}]

    {:ok, _blocked} = Cards.request_input(card, questions, :agent)

    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}?card=#{board.key}#{card.ref_number}")
    |> assert_has("#needs-input-panel")
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
end
