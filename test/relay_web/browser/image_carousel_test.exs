defmodule RelayWeb.Browser.ImageCarouselTest do
  @moduledoc """
  Real-browser (Playwright) tests for RE322's image carousel.

  Grouping, wrap-around, j/k/arrow stepping and — above all — key isolation from the card drawer
  behind the viewer live in `assets/js/image_lightbox.js`. `Phoenix.LiveViewTest` never runs that
  module (`render_keydown/3` pushes straight at the server), so only real clicks and keystrokes
  show that → steps the carousel *instead of* switching the card, and that Esc closes the viewer
  *instead of* the drawer. Same reasoning as `RelayWeb.Browser.TypingKeyGuardTest`.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright

  @screens [
    %{"url" => "/images/logo_light_128.png", "caption" => "One"},
    %{"url" => "/images/logo_dark_128.png", "caption" => "Two"},
    %{"url" => "/images/logo_transparent_128.png", "caption" => "Three"}
  ]

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))

    cards =
      for title <- ["Carousel A", "Carousel B", "Carousel C"] do
        {:ok, card} = Cards.create_card(code, %{title: title})
        card
      end

    # A leaked → and a leaked ← must each have a card to switch to, or isolation proves nothing.
    card =
      Enum.find(cards, fn card ->
        match?(%{prev: prev, next: next} when is_binary(prev) and is_binary(next), Cards.stage_neighbors(board, card))
      end)

    {:ok, card} = Cards.update_ai_result(card, %{"summary" => "Shipped", "screens" => @screens})
    # D1 — one image in a comment: its own group, separate from the screenshots.
    {:ok, _comment} = Activity.add_comment(card, %{actor: :agent, body: "![solo](/images/logo_dark_512.png)"})

    %{board: board, card: card}
  end

  defp open_screenshots(conn, board, card) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}?card=#{board.key}#{card.ref_number}")
    |> assert_has("#card-drawer-panel")
    # Keys pressed before LiveView binds its window listeners are lost (see TypingKeyGuardTest).
    |> assert_has("body .phx-connected")
    |> assert_has("#card-drawer-title", text: card.title)
    |> assert_has("#card-drawer-prev:not([disabled])")
    |> assert_has("#card-drawer-next:not([disabled])")
    |> click("#ai-result-show-more")
    |> assert_has("#ai-result-screens img")
  end

  # The key goes to the page with focus inside the open dialog, exactly as a human's does; the
  # listener under test is on window, so the focused element is irrelevant.
  defp press(session, key) do
    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.press(frame_id, selector: "#image-lightbox-img", key: key, timeout: 2_000)
    end)
  end

  defp assert_showing(session, caption, counter) do
    session
    |> assert_has("#image-lightbox-caption", text: caption)
    |> assert_has("#image-lightbox-counter", text: counter)
  end

  test "a screenshot opens the carousel, which steps and wraps by button, arrow and j/k without touching the card behind it",
       ctx do
    ctx.conn
    |> open_screenshots(ctx.board, ctx.card)
    |> click("#ai-result-screens figure:nth-child(2) img")
    |> assert_has("#image-lightbox[open]")
    |> assert_showing("Two", "2 / 3")
    |> assert_has("#image-lightbox-prev:not([hidden])")
    |> assert_has("#image-lightbox-next:not([hidden])")
    |> press("ArrowRight")
    |> assert_showing("Three", "3 / 3")
    # D2 — Next on the last wraps to the first.
    |> press("j")
    |> assert_showing("One", "1 / 3")
    |> click("#image-lightbox-next")
    |> assert_showing("Two", "2 / 3")
    |> press("ArrowLeft")
    |> assert_showing("One", "1 / 3")
    # D2 — Previous on the first wraps to the last.
    |> press("k")
    |> assert_showing("Three", "3 / 3")
    |> click("#image-lightbox-prev")
    |> assert_showing("Two", "2 / 3")
    |> press("Escape")
    |> refute_has("#image-lightbox[open]")
    # Ordered barrier: the LiveView handles its mailbox in order, so a prev_card / next_card /
    # close_drawer that any of the keys above leaked would be handled BEFORE this click — a closed
    # drawer has no stage chip to click, and a switched card fails the title assertion.
    |> click("#card-drawer-stage-chip")
    |> assert_has("#card-drawer-stage-menu")
    |> assert_has("#card-drawer-panel")
    |> assert_has("#card-drawer-title", text: ctx.card.title)
  end

  test "a lone comment image is its own group: no nav, no counter, and the keys do nothing", ctx do
    ctx.conn
    |> open_screenshots(ctx.board, ctx.card)
    |> assert_has("#card-drawer-conversation .md img[alt='solo']")
    |> click("#card-drawer-conversation .md img[alt='solo']")
    |> assert_has("#image-lightbox[open]")
    |> assert_has("#image-lightbox-caption", text: "solo")
    |> press("ArrowRight")
    |> press("j")
    |> assert_has("#image-lightbox-caption", text: "solo")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, displays} =
        Frame.evaluate(frame_id,
          expression: """
          (() => ["image-lightbox-prev", "image-lightbox-next", "image-lightbox-counter"]
            .map(id => getComputedStyle(document.getElementById(id)).display))()
          """,
          timeout: 2_000
        )

      assert displays == ["none", "none", "none"],
             "a lone image must show no Previous/Next or counter (computed display: #{inspect(displays)})"
    end)
    |> press("Escape")
    |> refute_has("#image-lightbox[open]")
    # …and the screenshots count only themselves, never the comment's image.
    |> click("#ai-result-screens figure:nth-child(1) img")
    |> assert_showing("One", "1 / 3")
    |> press("Escape")
    |> refute_has("#image-lightbox[open]")
    |> click("#card-drawer-stage-chip")
    |> assert_has("#card-drawer-stage-menu")
    |> assert_has("#card-drawer-title", text: ctx.card.title)
  end
end
