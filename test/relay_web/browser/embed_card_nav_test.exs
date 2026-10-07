defmodule RelayWeb.Browser.EmbedCardNavTest do
  @moduledoc """
  Real-browser (Playwright) test for RE400: on the native card host (`/cards/:ref?…&nav=…`) the
  drawer's ‹ › chevrons call the `relayCardNav` bridge instead of patching. Only a real browser
  runs the colocated `.NativeCardNav` hook.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 390, height: 844}]

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    review = Enum.find(board.stages, &(&1.name == "Review"))
    {:ok, card} = Cards.create_card(review, %{title: "Embedded nav card"})
    {:ok, card} = Cards.set_status(card, %{status: :in_review})
    %{board: board, ref: Cards.ref(board, card)}
  end

  defp measure(conn, expression) do
    parent = self()

    unwrap(conn, fn %{frame_id: frame_id} ->
      {:ok, value} = Frame.evaluate(frame_id, expression: expression, timeout: 2_000)
      send(parent, {:measured, value})
    end)

    assert_received {:measured, value}
    value
  end

  # Card mode renders only the fixed drawer, so wait for attachment rather than visibility.
  defp await_attached(conn, selector) do
    unwrap(conn, fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.wait_for_selector(frame_id, selector: selector, state: "attached", timeout: 5_000)
    end)
  end

  defp visit_card(conn, %{board: board, ref: ref}, nav) do
    conn =
      conn
      |> visit("/dev/login")
      |> assert_has("body .phx-connected")
      |> visit("/cards/#{ref}?board=#{board.slug}&embed=1&back=Board&nav=#{nav}")
      |> await_attached("[data-phx-main].phx-connected")
      |> await_attached("#card-drawer-nav")

    measure(
      conn,
      "(window.__calls = [], window.flutter_inappwebview = {callHandler: (...a) => window.__calls.push(a)}, true)"
    )

    conn
  end

  test "11. › then ‹ call relayCardNav and never navigate", %{conn: conn} = ctx do
    conn = visit_card(conn, ctx, "prev,next")

    conn = conn |> click("#card-drawer-next") |> click("#card-drawer-prev")
    # Give a (wrong) server patch time to round-trip before checking it never happened.
    Process.sleep(300)

    assert measure(conn, "window.__calls") == [["relayCardNav", "next"], ["relayCardNav", "prev"]]
    assert measure(conn, "location.pathname.endsWith(#{Jason.encode!(ctx.ref)})") == true
  end

  test "12. a missing direction is disabled and calls nothing", %{conn: conn} = ctx do
    conn = visit_card(conn, ctx, "next")

    assert measure(conn, ~s|document.querySelector("#card-drawer-prev").disabled|) == true
    measure(conn, ~s|(document.querySelector("#card-drawer-prev").click(), true)|)
    assert measure(conn, "window.__calls") == []
  end
end
