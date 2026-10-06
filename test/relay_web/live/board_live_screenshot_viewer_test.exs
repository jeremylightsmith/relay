defmodule RelayWeb.BoardLiveScreenshotViewerTest do
  @moduledoc """
  RE390 — `?card=<ref>&screenshot=<n>` opens the card's AI Result screenshot in the same-tab
  viewer RE380 built for mockups: only the Screenshots section in the sheet, ← → stay within it,
  Back/Esc return to the drawer, an invalid or stale `n` falls back to the drawer.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Attachments
  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    review = Enum.find(board.stages, &(&1.name == "Review"))

    card = in_review_card(review)
    s1 = upload(card, "s1.png", "image/png")
    s2 = upload(card, "s2.png", "image/png")
    h = upload(card, "h.html", Schemas.Attachment.html_type())
    mockups = for name <- ~w(a b c), do: upload(card, "#{name}.html", Schemas.Attachment.html_type())

    {:ok, card} =
      Cards.set_mockups(card, Enum.map(mockups, &%{"url" => RelayWeb.attachment_path(&1.id), "caption" => &1.filename}))

    {:ok, card} =
      Cards.update_ai_result(card, %{
        "summary" => "Built it",
        "screens" => [
          %{"url" => RelayWeb.attachment_path(s1.id), "caption" => "Board"},
          # An agent-local path the browser can't fetch: a placeholder tile, not a viewer item.
          # (update_ai_result/2 only takes objects, so the bare-path form rides in an object.)
          %{"url" => "tmp/smoke/12-review.png"},
          %{"url" => RelayWeb.attachment_path(s2.id), "caption" => "Review drawer"}
        ]
      })

    %{board: board, review: review, card: card, s1: s1, s2: s2, h: h}
  end

  defp in_review_card(stage, title \\ "Review me") do
    {:ok, card} = Cards.create_card(stage, %{title: title})
    {:ok, card} = Cards.set_status(card, %{status: :in_review})
    card
  end

  defp upload(card, name, type) do
    {:ok, attachment} =
      Attachments.create_attachment(card, %{filename: name, content_type: type, bytes: "#{name} bytes"})

    attachment
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  defp viewer(conn, board, n), do: open(conn, ~p"/board/#{board.slug}?card=MY1&screenshot=#{n}")

  defp refute_patched(%{proxy: {ref, topic, _}}), do: refute_received({^ref, {:patch, ^topic, _}})

  defp header_caption(view), do: view |> element("#mockup-viewer-header-caption") |> render() |> text()

  defp header_count(view), do: view |> element("#mockup-viewer-header-count") |> render() |> text()

  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  defp sheet(view), do: view |> element("#mockup-viewer-sheet") |> render()

  test "1. a screenshot tile opens the viewer with only the Screenshots section",
       %{conn: conn, board: board, s2: s2} do
    view = open(conn, ~p"/board/#{board.slug}?card=MY1")

    view |> element("#ai-result-show-more") |> render_click()
    view |> element("#ai-result-screen-2-open") |> render_click()

    assert_patch(view, ~p"/board/#{board.slug}?card=MY1&screenshot=2")
    assert has_element?(view, "#mockup-viewer")
    assert has_element?(view, "#mockup-viewer-mockups", "Screenshots")

    tiles = view |> sheet() |> LazyHTML.from_fragment() |> LazyHTML.query("#mockup-viewer-mockup-tiles > *")
    assert Enum.count(tiles) == 2

    assert header_caption(view) == "Review drawer"
    assert header_count(view) == "2 of 2"
    assert view |> element("#mockup-viewer-header-noun") |> render() |> text() == "Screenshot"
    refute has_element?(view, "#mockup-viewer-sheet #mockup-viewer-mockups-viewing")
    refute sheet(view) =~ "Mockups"
    refute sheet(view) =~ "Mockup:"
    assert has_element?(view, ~s|#mockup-viewer-image[src="#{RelayWeb.attachment_path(s2.id)}"]|)
    assert has_element?(view, "#card-drawer.hidden")
  end

  test "2. ← / → step within the screenshots and stop at the ends", %{conn: conn, board: board} do
    view = viewer(conn, board, 1)

    render_hook(view, "mockup_next", %{})
    assert_patch(view, ~p"/board/#{board.slug}?card=MY1&screenshot=2")

    render_hook(view, "mockup_next", %{})
    refute_patched(view)
    assert header_caption(view) == "Review drawer"
    assert header_count(view) == "2 of 2"
    refute has_element?(view, "#mockup-viewer-frame")

    view = viewer(conn, board, 1)
    render_hook(view, "mockup_prev", %{})
    refute_patched(view)
    assert header_count(view) == "1 of 2"
  end

  test "3. Esc (mockup_back) returns to the drawer", %{conn: conn, board: board} do
    view = viewer(conn, board, 2)

    render_hook(view, "mockup_back", %{})

    assert_patch(view, ~p"/board/#{board.slug}?card=MY1")
    refute has_element?(view, "#mockup-viewer")
    assert has_element?(view, "#card-drawer")
    refute has_element?(view, "#card-drawer.hidden")
  end

  test "4. a cold open waits for the async body instead of falling back", %{conn: conn, board: board} do
    view = viewer(conn, board, 1)

    refute_patched(view)
    assert has_element?(view, "#mockup-viewer")
    assert header_caption(view) == "Board"
    assert header_count(view) == "1 of 2"
  end

  for n <- ~w(99 0 abc 2x) do
    test "5. an invalid screenshot=#{n} falls back to the drawer", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, "/board/#{board.slug}?card=MY1&screenshot=#{unquote(n)}")
      render_async(view)

      assert_patch(view, ~p"/board/#{board.slug}?card=MY1")
      refute has_element?(view, "#mockup-viewer")
      assert has_element?(view, "#card-drawer")
    end
  end

  test "6. a card with no AI Result falls back to the drawer", %{conn: conn, board: board, review: review} do
    card = in_review_card(review, "No result")
    ref = Cards.ref(board, card)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}&screenshot=1")
    render_async(view)

    assert_patch(view, ~p"/board/#{board.slug}?card=#{ref}")
    refute has_element?(view, "#mockup-viewer")
  end

  test "7. a screenshot that goes away while on screen falls back to the drawer",
       %{conn: conn, board: board, card: card, s1: s1} do
    view = viewer(conn, board, 2)

    {:ok, _card} =
      Cards.update_ai_result(card, %{"screens" => [%{"url" => RelayWeb.attachment_path(s1.id), "caption" => "Board"}]})

    assert_patch(view, ~p"/board/#{board.slug}?card=MY1")
    refute has_element?(view, "#mockup-viewer")
  end

  test "8. an HTML screenshot is framed in the sandboxed iframe", %{conn: conn, board: board, card: card, h: h} do
    {:ok, _card} =
      Cards.update_ai_result(card, %{"screens" => [%{"url" => RelayWeb.attachment_path(h.id), "caption" => "Capture"}]})

    view = open(conn, ~p"/board/#{board.slug}?card=MY1")
    view |> element("#ai-result-show-more") |> render_click()
    view |> element("#ai-result-screen-0-open") |> render_click()
    assert_patch(view, ~p"/board/#{board.slug}?card=MY1&screenshot=1")

    assert has_element?(
             view,
             ~s|iframe#mockup-viewer-frame[sandbox="allow-scripts"][src="#{RelayWeb.attachment_path(h.id)}"]|
           )

    refute has_element?(view, "#mockup-viewer-image")
  end

  test "9. the top bar ends in Screenshots", %{conn: conn, board: board} do
    view = viewer(conn, board, 2)

    assert view |> element("#mockup-viewer-title") |> render() |> text() == "Screenshots"

    assert has_element?(
             view,
             ~s|#top-bar-crumb-card[href="/board/#{board.slug}?card=MY1"][data-phx-link="patch"]|
           )

    for id <- ~w(#board-name #board-view-tabs #agent-logs-button #board-settings-link) do
      refute has_element?(view, id), "#{id} should not render in viewer mode"
    end
  end

  describe "10. + Quote offers the screenshot's caption" do
    test "a captioned screenshot", %{conn: conn, board: board} do
      view = viewer(conn, board, 1)
      view |> element("#review-request-changes") |> render_click()

      assert view |> element("#review-quote-caption") |> render() |> text() == "+ Quote “Board”"
    end

    test "an uncaptioned screenshot", %{conn: conn, board: board, card: card, s1: s1} do
      {:ok, _card} = Cards.update_ai_result(card, %{"screens" => [%{"url" => RelayWeb.attachment_path(s1.id)}]})

      view = viewer(conn, board, 1)
      view |> element("#review-request-changes") |> render_click()

      assert view |> element("#review-quote-caption") |> render() |> text() == "+ Quote “Screenshot”"
    end
  end

  test "11. the story map and the card page host the screenshot viewer", %{conn: conn, board: board} do
    view = open(conn, ~p"/board/#{board.slug}/story-map?card=MY1&screenshot=1")
    assert has_element?(view, "#mockup-viewer")
    render_hook(view, "mockup_back", %{})
    assert_patch(view, ~p"/board/#{board.slug}/story-map?card=MY1")

    view = open(conn, ~p"/cards/MY1?board=#{board.slug}&screenshot=1")
    assert has_element?(view, "#mockup-viewer")
    render_hook(view, "mockup_back", %{})
    assert_patch(view, ~p"/cards/MY1?board=#{board.slug}")
  end

  test "12. the phone bar counts within the screenshots", %{conn: conn, board: board} do
    view = viewer(conn, board, 1)

    assert view |> element("#mockup-viewer-bar-count") |> render() |> text() == "1 / 2"
    assert view |> element("#mockup-viewer-bar-caption") |> render() |> text() == "Board"
    assert has_element?(view, "#mockup-viewer-bar-prev[disabled]")
    refute has_element?(view, "#mockup-viewer-bar-next[disabled]")
  end
end
