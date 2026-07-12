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
    |> visit("/board/#{board.slug}?card=#{board.key}-#{card.ref_number}")
    |> assert_has("#needs-input-panel")
    |> click("#needs-input-option-0")
    # the picked option must get the amber selected marker after a real click
    |> assert_has("#needs-input-option-0.needs-input-option-selected")
    |> click("#needs-input-send")
    |> assert_has("#card-drawer-conversation .timeline-comment-body", "Billing")
  end
end
