defmodule RelayWeb.CardMockupViewerEmbedTest do
  @moduledoc """
  RE393 · card mockup "Mockup viewer — one nav bar, phone/desktop toggle, pager above review
  bar": the card-mode (`/cards/:ref`) viewer embedded in the native app. One `mobile_nav_bar`
  ("‹ Card", the caption, the render-width toggle on HTML items) replaces the RE380 one-bar
  header, and a `mockup_viewer_pager` row (‹ dots n of m ›) sits under the frame.
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
    {:ok, card} = Cards.create_card(review, %{title: "Review me"})
    {:ok, card} = Cards.set_status(card, %{status: :in_review})

    [m1, m2] = mockups = for name <- ~w(a b), do: upload(card, "#{name}.html", Schemas.Attachment.html_type())
    {:ok, card} = Cards.set_mockups(card, entries(mockups))

    %{board: board, card: card, ref: Cards.ref(board, card), m1: m1, m2: m2}
  end

  @captions ["A — one list", "B — two panes"]

  defp upload(card, name, type) do
    {:ok, attachment} =
      Attachments.create_attachment(card, %{filename: name, content_type: type, bytes: "<p>#{name}</p>"})

    attachment
  end

  defp entries(attachments) do
    attachments
    |> Enum.zip(@captions)
    |> Enum.map(fn {a, caption} -> %{"url" => RelayWeb.attachment_path(a.id), "caption" => caption} end)
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  defp viewer(conn, board, ref, mockup),
    do: open(conn, ~p"/cards/#{ref}?board=#{board.slug}&embed=1&back=Board&mockup=#{mockup.id}")

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  test "3. one nav bar (‹ Card, caption, phone/desktop toggle) and a 1 of 2 pager",
       %{conn: conn, board: board, ref: ref, m1: m1} do
    view = viewer(conn, board, ref, m1)

    assert text(view, "#mockup-viewer-bar-back") == "Card"
    assert has_element?(view, ~s(a#mockup-viewer-bar-back[href="/cards/#{ref}?back=Board&board=#{board.slug}"]))
    assert text(view, "#mockup-viewer-bar-title") == "A — one list"
    refute has_element?(view, "#mockup-viewer-bar-count")

    assert has_element?(view, ~s(#mockup-viewer-width-phone[data-active="true"]))
    assert has_element?(view, ~s(#mockup-viewer-width-desktop[data-active="false"]))

    assert text(view, "#mockup-viewer-pager-count") == "1 of 2"
    assert has_element?(view, "#mockup-viewer-pager-prev[disabled]")
    assert has_element?(view, "#mockup-viewer-pager-next")
    refute has_element?(view, "#mockup-viewer-pager-next[disabled]")

    view |> element("#mockup-viewer-bar-back") |> render_click()
    assert_patch(view, "/cards/#{ref}?back=Board&board=#{board.slug}")
  end

  test "4. the pager's next patches to the second mockup and disables itself",
       %{conn: conn, board: board, ref: ref, m1: m1, m2: m2} do
    view = viewer(conn, board, ref, m1)

    view |> element("#mockup-viewer-pager-next") |> render_click()

    assert_patch(view, "/cards/#{ref}?back=Board&board=#{board.slug}&mockup=#{m2.id}")
    assert text(view, "#mockup-viewer-pager-count") == "2 of 2"
    assert has_element?(view, "#mockup-viewer-pager-next[disabled]")
  end

  test "5. an image item has the pager but no width toggle", %{conn: conn, board: board, card: card, ref: ref} do
    png = upload(card, "shot.png", "image/png")
    {:ok, _card} = Cards.set_mockups(card, [%{"url" => RelayWeb.attachment_path(png.id), "caption" => "Shot"}])

    view = viewer(conn, board, ref, png)

    assert has_element?(view, "#mockup-viewer-image")
    refute has_element?(view, "#mockup-viewer-width")
    assert has_element?(view, "#mockup-viewer-pager")
  end

  test "5. a screenshot item has the pager but no width toggle", %{conn: conn, board: board, card: card, ref: ref} do
    shot = upload(card, "shot.png", "image/png")

    {:ok, _card} =
      Cards.update_ai_result(card, %{
        "summary" => "Done",
        "screens" => [%{"url" => RelayWeb.attachment_path(shot.id), "caption" => "Shot"}]
      })

    view = open(conn, ~p"/cards/#{ref}?board=#{board.slug}&embed=1&back=Board&screenshot=1")

    assert has_element?(view, "#mockup-viewer-image")
    refute has_element?(view, "#mockup-viewer-width")
    assert has_element?(view, "#mockup-viewer-pager")
  end

  test "RE405 4. an embedded screenshot gets the zoom control and an image-kind box at Fit",
       %{conn: conn, board: board, card: card, ref: ref} do
    shot = upload(card, "shot.png", "image/png")

    {:ok, _card} =
      Cards.update_ai_result(card, %{
        "summary" => "Done",
        "screens" => [%{"url" => RelayWeb.attachment_path(shot.id), "caption" => "Shot"}]
      })

    view = open(conn, ~p"/cards/#{ref}?board=#{board.slug}&embed=1&back=Board&screenshot=1")

    assert has_element?(view, "#mockup-viewer-zoom")
    assert has_element?(view, ~s(#mockup-viewer-frame-box-1[data-kind=image][data-zoom="1"]))
    refute has_element?(view, "#mockup-viewer-width")
  end

  test "RE405 5. an embedded HTML mockup keeps the width toggle, zoom, phone render and sizer",
       %{conn: conn, board: board, ref: ref, m1: m1} do
    view = viewer(conn, board, ref, m1)

    assert has_element?(view, "#mockup-viewer-width")
    assert has_element?(view, "#mockup-viewer-zoom")
    assert has_element?(view, "[data-kind=html][data-render=phone]")
    assert has_element?(view, "#mockup-viewer-frame-sizer")
  end
end
