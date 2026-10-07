defmodule RelayWeb.Browser.TouchFieldSizeTest do
  @moduledoc """
  Real-browser (Playwright) test for RE400: on a touch device every text field computes to at
  least 16px, so iOS never zooms the page on focus — while the embedded title editor keeps the
  mobile scale's larger 22px title. Only a real browser evaluates the coarse-pointer media query
  and the cascade between the unlayered field rule and Tailwind's layered utilities.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 390, height: 844}, has_touch: true, is_mobile: true]

  @coarse ~s|matchMedia("(hover: none) and (pointer: coarse)").matches|

  defp card do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    [stage | _] = board.stages
    {:ok, card} = Cards.create_card(stage, %{title: "Touch field card"})
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

  defp font_size(conn, selector),
    do: measure(conn, ~s|parseFloat(getComputedStyle(document.querySelector("#{selector}")).fontSize)|)

  defp login(conn), do: conn |> visit("/dev/login") |> assert_has("body .phx-connected")

  defp await_connected(conn) do
    unwrap(conn, fn %{frame_id: frame_id} ->
      {:ok, _} =
        Frame.wait_for_selector(frame_id,
          selector: "[data-phx-main].phx-connected",
          state: "attached",
          timeout: 5_000
        )
    end)
  end

  test "on the web board a touch device's description editor is at least 16px", %{conn: conn} do
    {board, ref} = card()

    conn =
      conn
      |> login()
      |> visit("/board/#{board.slug}?card=#{ref}")
      |> click("#card-drawer-description-display")
      |> assert_has("#card-drawer-description-input")

    assert measure(conn, @coarse) == true
    assert font_size(conn, "#card-drawer-description-input") >= 16
  end

  test "on the web board a touch device's title editor keeps its 18px text-lg size", %{conn: conn} do
    {board, ref} = card()

    conn =
      conn
      |> login()
      |> visit("/board/#{board.slug}?card=#{ref}")
      |> click("#card-drawer-title-display")
      |> assert_has("#card-drawer-title-input")

    assert measure(conn, @coarse) == true
    assert font_size(conn, "#card-drawer-title-input") == 18
  end

  test "embedded, the title editor keeps the 22px title and the description editor is at least 16px",
       %{conn: conn} do
    {board, ref} = card()

    conn =
      conn
      |> login()
      |> visit("/cards/#{ref}?board=#{board.slug}&embed=1")
      |> await_connected()

    assert measure(conn, @coarse) == true

    conn =
      conn
      |> click("#card-drawer-title-display")
      |> assert_has("#card-drawer-title-input")

    assert font_size(conn, "#card-drawer-title-input") == 22

    conn =
      conn
      |> click("#card-drawer-description-display")
      |> assert_has("#card-drawer-description-input")

    assert font_size(conn, "#card-drawer-description-input") >= 16
  end
end
