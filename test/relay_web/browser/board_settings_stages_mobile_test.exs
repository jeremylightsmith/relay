defmodule RelayWeb.Browser.BoardSettingsStagesMobileTest do
  @moduledoc """
  Real-browser (Playwright) layout test for Board Settings → Stages at phone width (RE431, card
  mockup "A — stage row owns its flow"): the row's FLOW band, its PULLS FROM → WORKS IN → LANDS
  ON row and the inline delete-stage panel must all fit a 390px viewport without scrolling the
  page sideways. Only a real browser computes those boxes.

  The row is found through its flow chip (`[data-flow-key="code"]`), never a hard-coded stage
  id. The delete panel is only opened, never confirmed, so the dev-login board is untouched.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 390, height: 844}]

  @row ~s|document.querySelector('[data-flow-key="code"]').closest('[id$="-row"]')|

  # The band and the neighbours row: their own right edge and every descendant's.
  @measure_band """
  (() => {
    const cw = document.documentElement.clientWidth;
    const row = #{@row};
    const fits = (el) => {
      const overflowing = [el, ...el.querySelectorAll('*')]
        .filter((n) => n.getBoundingClientRect().width > 0 && n.getBoundingClientRect().right > cw + 1)
        .map((n) => n.id || n.className || n.tagName);
      return {right: el.getBoundingClientRect().right, overflowing};
    };
    return {scrollWidth: document.documentElement.scrollWidth, clientWidth: cw,
            band: fits(row.querySelector('[id$="-flow-band"]')),
            neighbours: fits(row.querySelector('[id$="-neighbours"]'))};
  })()
  """

  @measure_panel """
  (() => {
    const cw = document.documentElement.clientWidth;
    const row = #{@row};
    const panel = row.querySelector('[id$="-delete-panel"]');
    const box = (el) => { const r = el.getBoundingClientRect();
      return {left: r.left, right: r.right, width: r.width, height: r.height}; };
    const style = getComputedStyle(panel);
    return {scrollWidth: document.documentElement.scrollWidth, clientWidth: cw,
            visible: style.display !== 'none' && style.visibility !== 'hidden' && panel.offsetParent !== null,
            panel: box(panel),
            confirm: box(panel.querySelector('[id$="-delete-confirm"]')),
            cancel: box(panel.querySelector('[id$="-delete-cancel"]'))};
  })()
  """

  test "11. the Stages pane's FLOW band and neighbours row fit 390px", %{conn: conn} do
    conn
    |> open_stages()
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, m} = Frame.evaluate(frame_id, expression: @measure_band, timeout: 2_000)
      bound = m["clientWidth"] + 1

      assert m["scrollWidth"] <= bound, "the Stages pane scrolls sideways at 390px: #{inspect(m)}"

      for part <- ["band", "neighbours"] do
        assert m[part]["right"] <= bound, "the #{part} overflows at 390px: #{inspect(m[part])}"
        assert m[part]["overflowing"] == [], "inside the #{part} these overflow at 390px: #{inspect(m[part])}"
      end
    end)
  end

  test "12. the delete-stage panel opens inside 390px with both buttons visible", %{conn: conn} do
    conn
    |> open_stages()
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, delete_id} =
        Frame.evaluate(frame_id,
          expression: "#{@row}.querySelector('[id^=\"stage-\"][id$=\"-delete\"]').id",
          timeout: 2_000
        )

      {:ok, _} = Frame.click(frame_id, selector: "##{delete_id}", timeout: 2_000)
    end)
    |> assert_has(~s([id$="-delete-panel"]))
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, m} = Frame.evaluate(frame_id, expression: @measure_panel, timeout: 2_000)
      bound = m["clientWidth"] + 1

      assert m["visible"], "the delete panel is not visible: #{inspect(m)}"
      assert m["panel"]["right"] <= bound, "the delete panel overflows at 390px: #{inspect(m)}"

      for button <- ["confirm", "cancel"] do
        assert m[button]["left"] >= 0 and m[button]["right"] <= bound and m[button]["width"] > 0,
               "the #{button} button is not inside the viewport: #{inspect(m)}"
      end

      assert m["scrollWidth"] <= bound, "the open panel scrolls the page sideways: #{inspect(m)}"
    end)
  end

  defp open_stages(conn) do
    conn = conn |> visit("/dev/login") |> assert_has("body .phx-connected")
    board_path = unwrap_value(conn, "window.location.pathname")

    conn
    |> visit(board_path <> "/settings?section=stages")
    |> assert_has("body .phx-connected")
    |> assert_has(~s([data-flow-key="code"]))
  end

  defp unwrap_value(conn, expression) do
    parent = self()

    unwrap(conn, fn %{frame_id: frame_id} ->
      {:ok, value} = Frame.evaluate(frame_id, expression: expression, timeout: 2_000)
      send(parent, {:value, value})
    end)

    assert_received {:value, value}
    value
  end
end
