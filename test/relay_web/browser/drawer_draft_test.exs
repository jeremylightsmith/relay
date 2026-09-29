defmodule RelayWeb.Browser.DrawerDraftTest do
  @moduledoc """
  Real-browser (Playwright) tests for RE362. Clicking away from a drawer markdown editor used to
  cancel it (`phx-click-away`, RLY-49) and throw the typed text away; now only Save commits and
  only Cancel/Esc discard, and the unsaved text survives a card switch and a drawer close.

  `phx-click-away` is a client-side binding `Phoenix.LiveViewTest` never dispatches, so only a
  real click can prove the Description editor stays open while the single-line Title editor
  (`inline_field`, deliberately unchanged) still cancels. Same reasoning as
  `RelayWeb.Browser.TypingKeyGuardTest`.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))

    # Both cards carry a spec so the Spec header shows "Expand" — a harmless click target
    # elsewhere in the drawer (a blank spec's header would open the Spec editor instead).
    Enum.each(1..2, fn n ->
      {:ok, card} = Cards.create_card(code, %{title: "Draft keeper #{n}"})
      {:ok, _card} = Cards.update_card(card, %{spec: "## Existing spec\n\nSome text."})
    end)

    refs = board |> Cards.stage_column(code.id) |> Enum.map(&Cards.ref(board, &1))

    %{board: board, refs: refs}
  end

  test "a Description draft survives a click elsewhere, a card switch and a drawer close", ctx do
    [first, second | _rest] = ctx.refs

    ctx.conn
    |> visit_board("/board/#{ctx.board.slug}")
    |> click(board_card(first))
    |> assert_drawer_shows(first)
    |> click("#card-drawer-description-display")
    |> assert_has("#card-drawer-description-input")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} =
        Frame.type(frame_id, selector: "#card-drawer-description-input", text: "draft text 362", timeout: 2_000)
    end)
    # A real click elsewhere in the drawer. "Collapse" appearing proves the LiveView handled it,
    # so the editor still being there afterwards is a settled state, not a race.
    |> click("#card-drawer-spec-toggle")
    |> assert_has("#card-drawer-spec-toggle", text: "Collapse")
    |> assert_has("#card-drawer-description-input")
    |> assert_input_value("#card-drawer-description-input", "draft text 362")
    |> wait_for_debounce()
    |> click("#card-drawer-next")
    |> assert_drawer_shows(second)
    |> refute_has("#card-drawer-description-input")
    |> click("#card-drawer-close")
    |> refute_has("#card-drawer-panel")
    |> click(board_card(first))
    |> assert_drawer_shows(first)
    |> assert_has("#card-drawer-description-draft-restored", text: "Unsaved draft restored")
    |> assert_input_value("#card-drawer-description-input", "draft text 362")
  end

  test "the Title editor still cancels on click-away", ctx do
    [first | _rest] = ctx.refs
    title = Cards.get_card_by_ref(ctx.board, first).title

    ctx.conn
    |> visit_board("/board/#{ctx.board.slug}?card=#{first}")
    |> assert_drawer_shows(first)
    |> click("#card-drawer-title-display")
    |> assert_has("#card-drawer-title-input")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.type(frame_id, selector: "#card-drawer-title-input", text: " edited", timeout: 2_000)
    end)
    |> click("#card-drawer-spec-toggle")
    |> refute_has("#card-drawer-title-input")
    |> assert_has("#card-drawer-title-display", text: title, exact: true)

    assert Cards.get_card_by_ref(ctx.board, first).title == title
  end

  defp visit_board(conn, path) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit(path)
    # Wait for THIS page's socket — a click before LiveView binds is lost (see TypingKeyGuardTest).
    |> assert_has("body .phx-connected")
  end

  defp board_card(ref), do: ~s(.board-card[data-ref="#{ref}"])

  defp assert_drawer_shows(session, ref) do
    assert_has(session, "#card-drawer .drawer-card-ref", text: ref, exact: true)
  end

  defp assert_input_value(session, selector, expected) do
    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, value} = Frame.input_value(frame_id, selector: selector, timeout: 2_000)
      assert value == expected, "#{selector} held #{inspect(value)}, expected #{inspect(expected)}"
    end)
  end

  # The textarea's phx-change is debounced 300ms, and nothing on the page reflects the server
  # having stored the draft — so give the debounce time to fire before leaving the card.
  defp wait_for_debounce(session) do
    Process.sleep(600)
    session
  end
end
