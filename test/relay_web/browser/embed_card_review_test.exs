defmodule RelayWeb.Browser.EmbedCardReviewTest do
  @moduledoc """
  Real-browser (Playwright) test for RE393 · card mockup "Review card — web nav bar replaces
  the native AppBar": embedded at 390×844 a card in review renders one iOS nav bar
  ("‹ Board" in primary, a centered 17/600 ref, a 44px ⋯), a 32px stage chip, a 22/700 title
  and mobile-scale section labels. Only a real browser computes the sizes, and only a real
  browser runs the `.NativeBack` hook's `history.back()` fallback.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 390, height: 844}]

  defp review_card do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    review = Enum.find(board.stages, &(&1.name == "Review"))
    {:ok, card} = Cards.create_card(review, %{title: "Embedded review card"})
    {:ok, card} = Cards.set_status(card, %{status: :in_review})
    {board, Cards.ref(board, card)}
  end

  # Evaluates a JS expression in the page and returns its value.
  defp measure(conn, expression) do
    parent = self()

    unwrap(conn, fn %{frame_id: frame_id} ->
      {:ok, value} = Frame.evaluate(frame_id, expression: expression, timeout: 2_000)
      send(parent, {:measured, value})
    end)

    assert_received {:measured, value}
    value
  end

  # Card mode renders only the fixed drawer, so neither <html> nor the LiveView root has an
  # in-flow box and `assert_has/2` (which requires visibility) never matches them. Wait for the
  # element to be attached instead.
  defp await_attached(conn, selector) do
    unwrap(conn, fn %{frame_id: frame_id} ->
      {:ok, _} =
        Frame.wait_for_selector(frame_id, selector: selector, state: "attached", timeout: 5_000)
    end)
  end

  # The hooks (`.NativeBack`) are mounted once the root is connected.
  defp await_connected(conn), do: await_attached(conn, "[data-phx-main].phx-connected")

  defp card_url(board, ref), do: "/cards/#{ref}?board=#{board.slug}&embed=1&back=Board"

  defp visit_card(conn, board, ref) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit(card_url(board, ref))
    |> await_connected()
    |> assert_has("#card-drawer-nav-bar-back", text: "Board")
    |> assert_has("#card-drawer .section-label")
  end

  # A throwaway element styled with `var(--name)` reads the token's computed color.
  defp token_probe(property, var) do
    """
    (() => {
      const probe = document.createElement('div');
      probe.style.#{property} = 'var(#{var})';
      document.querySelector('main').appendChild(probe);
      const value = getComputedStyle(probe).#{property};
      probe.remove();
      return value;
    })()
    """
  end

  test "the nav bar, chip, title and labels follow the iOS scale", %{conn: conn} do
    {board, ref} = review_card()
    conn = visit_card(conn, board, ref)
    primary = measure(conn, token_probe("color", "--color-primary"))

    m =
      measure(conn, """
      (() => {
        const bar = document.querySelector('#card-drawer-nav-bar');
        const cs = getComputedStyle(bar);
        const back = getComputedStyle(document.querySelector('#card-drawer-nav-bar-back'));
        const title = getComputedStyle(document.querySelector('#card-drawer-nav-bar-title'));
        const cardTitle = getComputedStyle(document.querySelector('#card-drawer-title-display'));
        const label = getComputedStyle(document.querySelector('#card-drawer .section-label'));
        return {
          barContent: bar.getBoundingClientRect().height - parseFloat(cs.paddingTop)
                      - parseFloat(cs.borderBottomWidth),
          backSize: back.fontSize, backColor: back.color,
          titleSize: title.fontSize, titleWeight: title.fontWeight,
          cardTitleSize: cardTitle.fontSize, cardTitleWeight: cardTitle.fontWeight,
          chipH: document.querySelector('#card-drawer-stage-chip').getBoundingClientRect().height,
          labelSize: label.fontSize, labelTransform: label.textTransform,
          overflowW: document.querySelector('#card-drawer-overflow').getBoundingClientRect().width
        };
      })()
      """)

    assert m["barContent"] == 44, inspect(m)
    assert m["backSize"] == "17px", inspect(m)
    assert m["backColor"] == primary, inspect({m, primary})
    assert m["titleSize"] == "17px", inspect(m)
    assert m["titleWeight"] == "600", inspect(m)
    assert m["cardTitleSize"] == "22px", inspect(m)
    assert m["cardTitleWeight"] == "700", inspect(m)
    assert m["chipH"] == 32, inspect(m)
    assert m["labelSize"] == "12px", inspect(m)
    assert m["labelTransform"] == "uppercase", inspect(m)
    assert m["overflowW"] >= 44, inspect(m)
  end

  test "outside the app, back falls back to history.back()", %{conn: conn} do
    {board, ref} = review_card()

    conn =
      conn
      |> visit("/dev/login")
      |> assert_has("body .phx-connected")
      |> visit("/board/#{board.slug}?embed=1")
      |> assert_has("main[data-embed] #board-create-card")

    # A real navigation (not visit/2's goto) so the board stays in this tab's history.
    measure(conn, "window.location.assign('#{card_url(board, ref)}')")

    conn =
      conn
      |> assert_has("#card-drawer-nav-bar-back", text: "Board")
      |> await_connected()
      |> click("#card-drawer-nav-bar-back")
      |> assert_has("main[data-embed] #board-create-card")

    assert measure(conn, "window.location.pathname + window.location.search") ==
             "/board/#{board.slug}?embed=1"
  end

  test "dark theme: the bar and active segment take the dark tokens", %{conn: conn} do
    {board, ref} = review_card()

    conn =
      conn
      |> visit_card(board, ref)
      |> tap(&measure(&1, "localStorage.setItem('phx:theme', 'dark')"))
      |> visit(card_url(board, ref))
      |> await_attached("html[data-theme=dark]")
      |> assert_has("#card-drawer-nav-bar-back", text: "Board")
      |> assert_has("#card-drawer-tab-detail[data-active=true]")

    base100 = measure(conn, token_probe("backgroundColor", "--color-base-100"))

    m =
      measure(conn, """
      (() => ({
        bar: getComputedStyle(document.querySelector('#card-drawer-nav-bar')).backgroundColor,
        segment: getComputedStyle(document.querySelector('#card-drawer-tab-detail')).backgroundColor
      }))()
      """)

    refute m["bar"] == "rgb(255, 255, 255)", inspect(m)
    assert m["segment"] == base100, inspect({m, base100})
  end
end
