defmodule RelayWeb.Browser.FlowShapeMobileTest do
  @moduledoc """
  Real-browser (Playwright) layout test for RE432's broken-shape surfaces at phone width (card
  mockups "B — broken-shape callouts on the paused stage rows (all four problems)" and "C — board
  banner per paused flow, with Fix in Stages"): at 390px the Stages callout's FIX buttons and the
  board banner's **Fix in Stages →** go full-width without scrolling the page sideways, and the
  Fix link lands on the broken stage row scrolled into view. Only a real browser computes those
  boxes and that scroll position.

  Each test breaks the dev-login board's shape inside its own sandbox: it copies the `code` flow
  onto Deploy and turns it on, so Deploy pulls straight from Review and the flow pauses. The row
  is found through the flow chip (`[data-flow-key="code-deploy"]`), never a hard-coded stage id.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Flows

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 390, height: 844}]

  @flow_key "code-deploy"

  @row ~s|document.querySelector('[data-flow-key="#{@flow_key}"][data-flow-paused="true"]').closest('[id$="-row"]')|

  # The paused row's callout: page overflow, the callout's own box and descendants, each FIX
  # button against its FIX row, and the BOARD ORDER strip against the callout's content box.
  @measure_callout """
  (() => {
    const cw = document.documentElement.clientWidth;
    const callout = #{@row}.querySelector('[id$="-shape-callout"]');
    const rect = callout.getBoundingClientRect();
    const style = getComputedStyle(callout);
    const overflowing = [...callout.querySelectorAll('*')]
      .filter((n) => n.getBoundingClientRect().width > 0 && n.getBoundingClientRect().right > rect.right + 1)
      .map((n) => n.id || n.className || n.tagName);
    const fixes = [...callout.querySelectorAll('[id*="-shape-callout-fix-"]')]
      .map((b) => ({id: b.id, width: b.getBoundingClientRect().width, rowWidth: b.parentElement.clientWidth}));
    return {scrollWidth: document.documentElement.scrollWidth, clientWidth: cw,
            right: rect.right, overflowing, fixes,
            contentLeft: rect.left + parseFloat(style.borderLeftWidth) + parseFloat(style.paddingLeft),
            orderLeft: callout.querySelector('[id$="-shape-callout-order"]').getBoundingClientRect().left};
  })()
  """

  @measure_banner """
  (() => {
    const cw = document.documentElement.clientWidth;
    const banner = document.querySelector('#paused-flow-banner-#{@flow_key}');
    const rect = banner.getBoundingClientRect();
    const style = getComputedStyle(banner);
    return {scrollWidth: document.documentElement.scrollWidth, clientWidth: cw,
            visible: style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0
                     && rect.top >= 0 && rect.top < window.innerHeight,
            right: rect.right,
            contentWidth: banner.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight),
            fixWidth: document.querySelector('#paused-flow-banner-#{@flow_key}-fix').getBoundingClientRect().width};
  })()
  """

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    deploy = Enum.find(board.stages, &(&1.name == "Deploy" and is_nil(&1.parent_id)))
    {:ok, flow} = Flows.copy_flow(Flows.get_flow!(board, "code"), deploy)
    {:ok, _} = Flows.enable_flow(flow)
    %{board: board, deploy: deploy}
  end

  test "1. the paused row's callout fits 390px with full-width FIX buttons", %{
    conn: conn,
    board: board
  } do
    conn
    |> open(board, "/settings?section=stages")
    |> assert_has(~s([id$="-shape-callout-fix-1"]))
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, m} = Frame.evaluate(frame_id, expression: @measure_callout, timeout: 2_000)
      bound = m["clientWidth"] + 1

      assert m["scrollWidth"] <= bound, "the Stages pane scrolls sideways at 390px: #{inspect(m)}"
      assert m["right"] <= bound, "the callout overflows at 390px: #{inspect(m)}"
      assert m["overflowing"] == [], "inside the callout these overflow: #{inspect(m)}"

      assert length(m["fixes"]) == 2, "expected two FIX buttons: #{inspect(m["fixes"])}"

      for fix <- m["fixes"] do
        assert abs(fix["width"] - fix["rowWidth"]) <= 2,
               "FIX button #{fix["id"]} is not full-width at 390px: #{inspect(fix)}"
      end

      assert abs(m["orderLeft"] - m["contentLeft"]) <= 1,
             "the BOARD ORDER strip keeps its desktop indent at 390px: #{inspect(m)}"
    end)
  end

  test "2. the board banner fits 390px with a full-width Fix in Stages button", %{
    conn: conn,
    board: board
  } do
    conn
    |> open(board, "")
    |> assert_has("#paused-flow-banner-#{@flow_key}-fix")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, m} = Frame.evaluate(frame_id, expression: @measure_banner, timeout: 2_000)
      bound = m["clientWidth"] + 1

      assert m["visible"], "the banner is not on screen: #{inspect(m)}"
      assert m["right"] <= bound, "the banner overflows at 390px: #{inspect(m)}"
      assert m["scrollWidth"] <= bound, "the board scrolls sideways at 390px: #{inspect(m)}"

      assert abs(m["fixWidth"] - m["contentWidth"]) <= 2,
             "Fix in Stages is not full-width at 390px: #{inspect(m)}"
    end)
  end

  test "3. Fix in Stages lands on the broken stage row, scrolled into view", %{
    conn: conn,
    board: board,
    deploy: deploy
  } do
    conn
    |> open(board, "")
    |> click("#paused-flow-banner-#{@flow_key}-fix")
    |> assert_has("#stages-pane")
    |> assert_has("body .phx-connected")
    |> assert_path("/board/#{board.slug}/settings")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, m} =
        Frame.evaluate(frame_id,
          expression: """
          (() => ({search: location.search, hash: location.hash,
                   top: document.querySelector('#stage-#{deploy.id}-row').getBoundingClientRect().top,
                   innerHeight: window.innerHeight, scrollY: window.scrollY}))()
          """,
          timeout: 2_000
        )

      assert m["search"] == "?section=stages"
      assert m["hash"] == "#stage-#{deploy.id}-row"

      # ±1px: the fragment scroll lands the row's top on a sub-pixel boundary.
      assert m["top"] >= -1 and m["top"] < m["innerHeight"],
             "the Deploy row is not scrolled into view: #{inspect(m)}"

      assert m["scrollY"] > 0, "the page was left at its top, not scrolled to the row: #{inspect(m)}"
    end)
  end

  defp open(conn, board, suffix) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}" <> suffix)
    |> assert_has("body .phx-connected")
  end
end
