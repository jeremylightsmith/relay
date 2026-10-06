defmodule RelayWeb.Browser.SavePendingTest do
  @moduledoc """
  Real-browser (Playwright) test for RE394 · card mockup "A — the pressed button spins and says
  what it's doing", for saves: the commit pill's ✓ (every `inline_field` / `boxed_field` read-edit
  field) and a `boxed_field` editor's Save show the pressed face in the click's own frame while
  the rest of their group goes inert, and the server's reply clears it.

  The face is pure CSS keyed on LiveView's client-side `phx-submit-loading` class, so only a real
  browser can see it. `liveSocket.enableLatencySim/1` holds the reply back long enough to read the
  pressed state; it persists in `sessionStorage`, so every test turns it off again at the end.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright

  @latency_ms 1_500
  @reply_timeout 6_000

  setup do
    user = Accounts.ensure_dev_user!()
    %{board: Boards.get_or_create_default_board(user)}
  end

  test "the Board name ✓ presses in place: spinner, hint reads Saving…, ✕ inert, same width", %{
    conn: conn,
    board: board
  } do
    original = board.name
    renamed = "Relay board RE394"

    conn
    |> visit_page("/board/#{board.slug}/settings?section=general", "#board-name-input")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.fill(frame_id, selector: "#board-name-input", value: renamed, timeout: 2_000)
    end)
    |> assert_has("#board-name-save", timeout: @reply_timeout)
    |> latency_on()
    |> unwrap(fn %{frame_id: frame_id} ->
      width = probe(frame_id, "#board-name-save")["width"]
      {:ok, _} = Frame.click(frame_id, selector: "#board-name-save", timeout: 2_000)

      save = probe(frame_id, "#board-name-save")
      assert "phx-submit-loading" in save["classes"]
      assert_in_delta save["width"], width, 0.5
      assert probe(frame_id, "#board-name-save .pending-face")["visibility"] == "visible"
      assert probe(frame_id, "#board-name-save .pending-idle")["visibility"] == "hidden"

      hint = probe(frame_id, "#board-name-pill .pending-status .pending-face")
      assert hint["visibility"] == "visible"
      assert hint["text"] == "Saving…"

      assert_inert(frame_id, "#board-name-cancel")
    end)
    |> assert_has("#flash-info", text: "Board name saved.", timeout: @reply_timeout)
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, value} = Frame.input_value(frame_id, selector: "#board-name-input", timeout: 2_000)
      assert value == renamed
      refute "phx-submit-loading" in probe(frame_id, "#board-name-save")["classes"]
    end)
    |> latency_off()

    {:ok, _} = board.id |> Boards.get_board_by_id!() |> Boards.update_board(%{name: original})
  end

  test "a Description editor's Save presses in place without daisyUI's disabled grey; Cancel inert", %{
    conn: conn,
    board: board
  } do
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: "Pressed description save"})

    conn
    |> visit_page("/board/#{board.slug}?card=#{board.key}#{card.ref_number}", "#card-drawer-description-display")
    |> click("#card-drawer-description-display")
    |> assert_has("#card-drawer-description-input")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} =
        Frame.type(frame_id, selector: "#card-drawer-description-input", text: "pressed save 394", timeout: 2_000)
    end)
    # The textarea's phx-change is debounced 300ms — let it land before holding replies back.
    |> wait_for_debounce()
    |> latency_on()
    |> unwrap(fn %{frame_id: frame_id} ->
      before = probe(frame_id, "#card-drawer-description-save")
      {:ok, _} = Frame.click(frame_id, selector: "#card-drawer-description-save", timeout: 2_000)

      # daisyUI's .btn transitions its background; the click's own hover (dropped again by the
      # pressed face's pointer-events: none) leaves one running — read the settled colour.
      settle_transitions(frame_id, "#card-drawer-description-save")
      save = probe(frame_id, "#card-drawer-description-save")
      assert "phx-submit-loading" in save["classes"]
      assert_in_delta save["width"], before["width"], 0.5
      # LiveView disables the submitting form's buttons; daisyUI's :disabled grey must not win.
      assert save["background"] == before["background"]
      assert save["color"] == before["color"]

      face = probe(frame_id, "#card-drawer-description-save .pending-face")
      assert face["visibility"] == "visible"
      assert face["text"] == "Saving…"

      assert_inert(frame_id, "#card-drawer-description-cancel")
    end)
    |> refute_has("#card-drawer-description-input", timeout: @reply_timeout)
    |> assert_has("#card-drawer-description-view", text: "pressed save 394", timeout: @reply_timeout)
    |> latency_off()
  end

  defp visit_page(conn, path, ready_selector) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit(path)
    |> assert_has(ready_selector)
    # Wait for THIS page's socket — a click before LiveView binds is lost.
    |> assert_has("body .phx-connected")
  end

  defp wait_for_debounce(session) do
    Process.sleep(600)
    session
  end

  defp settle_transitions(frame_id, selector) do
    eval!(frame_id, """
    (async () => {
      const el = document.querySelector(#{Jason.encode!(selector)});
      await Promise.all(el.getAnimations().map(a => a.finished.catch(() => null)));
      return true;
    })()
    """)
  end

  defp latency_on(session) do
    unwrap(session, fn %{frame_id: frame_id} ->
      eval!(frame_id, "(window.liveSocket.enableLatencySim(#{@latency_ms}), true)")
    end)
  end

  defp latency_off(session) do
    unwrap(session, fn %{frame_id: frame_id} ->
      eval!(frame_id, "(window.liveSocket.disableLatencySim(), true)")
    end)
  end

  defp eval!(frame_id, js) do
    {:ok, value} = Frame.evaluate(frame_id, expression: "(() => #{js})()", timeout: 2_000)
    value
  end

  # The element's classes, rendered width and text, and the computed styles the pressed face and
  # the inert group change.
  defp probe(frame_id, selector) do
    frame_id
    |> eval!("""
    (() => {
      const el = document.querySelector(#{Jason.encode!(selector)});
      if (!el) return JSON.stringify(null);
      const cs = getComputedStyle(el);
      return JSON.stringify({
        classes: [...el.classList],
        width: el.getBoundingClientRect().width,
        text: el.innerText.trim(),
        visibility: cs.visibility,
        background: cs.backgroundColor,
        color: cs.color,
        opacity: cs.opacity,
        pointerEvents: cs.pointerEvents
      });
    })()
    """)
    |> Jason.decode!()
    |> tap(&assert(&1, "#{selector} is not on the page"))
  end

  defp assert_inert(frame_id, selector) do
    sibling = probe(frame_id, selector)
    assert sibling["opacity"] == "0.4", "#{selector} opacity is #{sibling["opacity"]}"
    assert sibling["pointerEvents"] == "none", "#{selector} pointer-events is #{sibling["pointerEvents"]}"
  end
end
