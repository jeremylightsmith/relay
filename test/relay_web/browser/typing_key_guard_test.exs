defmodule RelayWeb.Browser.TypingKeyGuardTest do
  @moduledoc """
  Real-browser (Playwright) regression test for RE306.

  The drawer's `t` -> Talk hotkey is bound with `phx-window-keydown` + `phx-key="t"` and guarded
  client-side by `TypingKeyGuard`. The guard matched `e.key` case-SENSITIVELY while LiveView
  matches `phx-key` case-INSENSITIVELY, so a capital `T` typed into any card text field slipped
  past the guard, reached a `handle_event` clause that only matched `%{"key" => "t"}`, and took
  the whole board LiveView down.

  `render_keydown/3` in `Phoenix.LiveViewTest` pushes the event straight at the server and never
  runs the JS guard, so the client half of this bug is invisible to a LiveView test — only real
  keystrokes, round-tripped through an actual browser, catch it. Same reasoning as
  `RelayWeb.Browser.NeedsInputStepperTest` for real clicks.
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
    {:ok, card} = Cards.create_card(code, %{title: "Guarded typing"})

    %{board: board, card: card}
  end

  defp open_drawer(conn, board, card) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}?card=#{board.key}#{card.ref_number}")
    |> assert_has("#card-drawer-panel")
    # The panel is server-rendered, so it is present before the socket connects — and a keypress
    # that lands before LiveView binds its window keydown listener is simply lost. Every test here
    # presses keys, so wait for the connected socket on THIS page (the helper's earlier
    # `.phx-connected` was asserted on /dev/login, which we have since navigated away from).
    |> assert_has("body .phx-connected")
  end

  test "a capital typed into the Move-to filter leaves the menu standing", ctx do
    ctx.conn
    |> open_drawer(ctx.board, ctx.card)
    |> click("#card-drawer-stage-chip")
    # assert_has waits for the input to be in the DOM; Frame.type below does auto-wait, but the
    # focus/value reads afterwards do not.
    |> assert_has("#card-drawer-stage-filter")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} =
        Frame.type(frame_id, selector: "#card-drawer-stage-filter", text: "Tes", timeout: 2_000)
    end)
    # No seeded stage matches "Tes", and the filtered list is server-rendered from @stage_filter,
    # so this only appears once the LiveView has processed all three keystrokes — an ordered
    # barrier a crash on the `T` could not have got past.
    |> assert_has("#card-drawer-stage-none")
    |> assert_has("#card-drawer-stage-menu")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, value} =
        Frame.input_value(frame_id, selector: "#card-drawer-stage-filter", timeout: 2_000)

      assert value == "Tes", "the capital T never landed in the filter (got #{inspect(value)})"

      {:ok, focused} =
        Frame.evaluate(frame_id,
          expression: "(() => document.activeElement && document.activeElement.id)()",
          timeout: 2_000
        )

      assert focused == "card-drawer-stage-filter",
             "focus escaped the filter to #{inspect(focused)} — the drawer was torn down"
    end)
  end

  # The Move-to filter above is an <input>; the note box is a <textarea>. Both are in the guard's
  # definition of "typing", and the reported symptom ("you get sent to the talk tab") was seen
  # while typing a note, so pin that element too.
  test "a capital typed into the note box leaves the Detail tab and the text intact", ctx do
    ctx.conn
    |> open_drawer(ctx.board, ctx.card)
    |> assert_has("#card-drawer-comment-input")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} =
        Frame.type(frame_id,
          selector: "#card-drawer-comment-input",
          text: "The Team should test this",
          timeout: 5_000
        )
    end)
    # Ordered barrier again: this click is handled after every keystroke's `validate_comment`, so
    # a crash mid-sentence could not leave the menu open.
    |> click("#card-drawer-stage-chip")
    |> assert_has("#card-drawer-stage-menu")
    |> assert_has("#card-drawer-tab-detail[data-active='true']")
    |> refute_has("#card-drawer-tab-talk[data-active='true']")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, value} =
        Frame.input_value(frame_id, selector: "#card-drawer-comment-input", timeout: 2_000)

      assert value == "The Team should test this",
             "the note lost characters to the hotkey (got #{inspect(value)})"
    end)
  end

  test "Shift+T still opens Talk when no text field has focus", ctx do
    ctx.conn
    |> open_drawer(ctx.board, ctx.card)
    |> assert_has("#card-drawer-tab-detail[data-active='true']")
    # Pressing on the (focusable, non-text) tab button is the "not typing" case: the guard must
    # let it through, and the case-folded phx-key match must still fire the shortcut.
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} =
        Frame.press(frame_id, selector: "#card-drawer-tab-detail", key: "Shift+T", timeout: 2_000)
    end)
    |> assert_has("#card-drawer-tab-talk[data-active='true']")
  end

  test "Ctrl+T belongs to the browser, not to the drawer", ctx do
    ctx.conn
    |> open_drawer(ctx.board, ctx.card)
    |> click("#card-drawer-tab-activity")
    |> assert_has("#card-drawer-tab-activity[data-active='true']")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} =
        Frame.press(frame_id,
          selector: "#card-drawer-tab-activity",
          key: "Control+t",
          timeout: 2_000
        )
    end)
    # Ordered barrier: the LiveView handles its mailbox in order, so had Ctrl+T pushed
    # `talk_shortcut` it would have been handled BEFORE this click. The menu being open therefore
    # proves the tab assertions below read a settled state rather than racing the keypress.
    |> click("#card-drawer-stage-chip")
    |> assert_has("#card-drawer-stage-menu")
    |> refute_has("#card-drawer-tab-talk[data-active='true']")
    |> assert_has("#card-drawer-tab-activity[data-active='true']")
  end

  # RE306 round 2 — the four tests above all put the caret in the field first (`Frame.type`
  # focuses its selector). A human does not: they click the stage chip and type, and the menu
  # opens with focus still ON THE CHIP. Pressing on the chip reproduces that focus state exactly,
  # with no timing dependency.
  test "the Move-to menu standing open switches the `t` hotkey off", ctx do
    ctx.conn
    |> open_drawer(ctx.board, ctx.card)
    |> assert_has("#card-drawer-tab-detail[data-active='true']")
    |> click("#card-drawer-stage-chip")
    |> assert_has("#card-drawer-stage-filter")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} =
        Frame.press(frame_id, selector: "#card-drawer-stage-chip", key: "t", timeout: 2_000)

      # Ordered barrier: the LiveView handles its mailbox in order, so a `talk_shortcut` pushed
      # by that keypress is handled BEFORE this filter change. No seeded stage matches "zzzz".
      {:ok, _} =
        Frame.type(frame_id, selector: "#card-drawer-stage-filter", text: "zzzz", timeout: 2_000)
    end)
    |> assert_has("#card-drawer-stage-none")
    |> assert_has("#card-drawer-stage-menu")
    |> assert_has("#card-drawer-tab-detail[data-active='true']")
    |> refute_has("#card-drawer-tab-talk[data-active='true']")
  end

  # And the other focus window: a click-to-edit editor is open, but the key lands somewhere that
  # is not a text field — which is what happens for real in the round trip between clicking the
  # display <div> and its <textarea> existing.
  test "an open click-to-edit editor switches the `t` hotkey off", ctx do
    ctx.conn
    |> open_drawer(ctx.board, ctx.card)
    |> assert_has("#card-drawer-tab-detail[data-active='true']")
    |> click("#card-drawer-description-display")
    |> assert_has("#card-drawer-description-input")
    |> unwrap(fn %{frame_id: frame_id} ->
      # A focusable non-text element inside the drawer. `press` focuses without clicking, so the
      # editor's phx-click-away does not fire and the editor stays open.
      {:ok, _} =
        Frame.press(frame_id, selector: "#card-drawer-tab-detail", key: "t", timeout: 2_000)
    end)
    # Ordered barrier: this click is handled after the keypress above, so the menu being open
    # proves the tab assertions read a settled state. (The click also cancels the editor via
    # phx-click-away — that is fine, the gate was consulted before it.)
    |> click("#card-drawer-stage-chip")
    |> assert_has("#card-drawer-stage-menu")
    |> assert_has("#card-drawer-tab-detail[data-active='true']")
    |> refute_has("#card-drawer-tab-talk[data-active='true']")
  end
end
