defmodule RelayWeb.BoardLiveNoteImagesTest do
  @moduledoc """
  RE427 — a posted note's images render as a wrapping row of 108px thumbnails under the note, and
  a thumbnail opens BoardLive's same-tab viewer at `?image=<attachment id>`, paging oldest-first
  through every note image on the card ("Image n of N", "From a note by …").
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Activity
  alias Relay.Attachments
  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    review = Enum.find(board.stages, &(&1.name == "Review"))
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(review, %{title: "Review me"})

    %{board: board, card: card, code: code, user: user}
  end

  defp image(card, name) do
    {:ok, attachment} =
      Attachments.create_attachment(card, %{filename: name, content_type: "image/png", bytes: "png #{name}"})

    attachment
  end

  defp note(card, user, body, images) do
    {:ok, comment} =
      Activity.add_comment(card, %{actor: {:user, user.id}, body: body, image_ids: Enum.map(images, & &1.id)})

    comment
  end

  # Two notes, three images: note 1 carries i1, i2; note 2 carries i3.
  defp two_notes(%{card: card, user: user}) do
    [i1, i2, i3] = for name <- ~w(overflow.png phone.png drawer.png), do: image(card, name)
    n1 = note(card, user, "first", [i1, i2])
    n2 = note(card, user, "second", [i3])
    %{i1: i1, i2: i2, i3: i3, n1: n1, n2: n2}
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  defp text(view, selector),
    do: view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() |> squish()

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  defp src(id), do: RelayWeb.attachment_path(id)

  describe "the posted thumbnail row" do
    test "3. a note with two images renders both thumbnails and its body", %{conn: conn, board: board} = ctx do
      [a, b] = for name <- ~w(a.png b.png), do: image(ctx.card, name)
      comment = note(ctx.card, ctx.user, "see screenshots", [a, b])

      view = open(conn, ~p"/board/#{board.slug}?card=MY1")
      row = "#timeline-comment-#{comment.id}-images"

      assert has_element?(view, row)
      assert view |> element(row) |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("a") |> Enum.count() == 2
      assert has_element?(view, ~s|#{row} a img[src="#{src(a.id)}"]|)
      assert has_element?(view, ~s|#{row} a img[src="#{src(b.id)}"]|)
      assert has_element?(view, "#timeline-comment-#{comment.id} .timeline-comment-body", "see screenshots")
    end

    test "4. an image-only note shows the row and no body box", %{conn: conn, board: board} = ctx do
      comment = note(ctx.card, ctx.user, "", [image(ctx.card, "only.png")])

      view = open(conn, ~p"/board/#{board.slug}?card=MY1")

      assert has_element?(view, "#timeline-comment-#{comment.id} #timeline-comment-#{comment.id}-images")
      refute has_element?(view, "#timeline-comment-#{comment.id} .timeline-comment-body")
    end

    test "5. a note posted elsewhere shows its thumbnail live", %{conn: conn, board: board} = ctx do
      view = open(conn, ~p"/board/#{board.slug}?card=MY1")
      shot = image(ctx.card, "live.png")

      comment = note(ctx.card, ctx.user, "from another session", [shot])

      assert has_element?(view, ~s|#timeline-comment-#{comment.id}-images img[src="#{src(shot.id)}"]|)
    end
  end

  describe "the images viewer" do
    setup :two_notes

    test "6. a thumbnail opens the viewer on that image", %{conn: conn, board: board, n2: n2, i3: i3} = ctx do
      view = open(conn, ~p"/board/#{board.slug}?card=MY1")

      view |> element("#timeline-comment-#{n2.id}-images-#{i3.id}") |> render_click()

      assert_patch(view, ~p"/board/#{board.slug}?card=MY1&image=#{i3.id}")
      assert has_element?(view, "#mockup-viewer")
      assert has_element?(view, ~s|#mockup-viewer-image[src="#{src(i3.id)}"]|)
      assert text(view, "#mockup-viewer-header-count") == "Image 3 of 3"
      assert text(view, "#mockup-viewer-byline") == "From a note by #{ctx.user.name || ctx.user.email} · just now"
      assert text(view, "#mockup-viewer-mockups .section-label") == "Images · 3"
    end

    test "7. ← pages to the previous image and Esc returns to the drawer",
         %{conn: conn, board: board, i2: i2, i3: i3} do
      view = open(conn, ~p"/board/#{board.slug}?card=MY1&image=#{i3.id}")

      view |> element("#mockup-viewer-key-prev") |> render_keydown(%{"key" => "ArrowLeft"})
      assert_patch(view, ~p"/board/#{board.slug}?card=MY1&image=#{i2.id}")
      assert text(view, "#mockup-viewer-header-count") == "Image 2 of 3"

      render_hook(view, "mockup_back", %{})
      assert_patch(view, ~p"/board/#{board.slug}?card=MY1")
      refute has_element?(view, "#mockup-viewer")
      assert has_element?(view, "#card-drawer")
      refute has_element?(view, "#card-drawer.hidden")
    end

    test "8. a cold open shows the named image once the body loads", %{conn: conn, board: board, i1: i1} do
      view = open(conn, ~p"/board/#{board.slug}?card=MY1&image=#{i1.id}")

      assert has_element?(view, ~s|#mockup-viewer-image[src="#{src(i1.id)}"]|)
      assert text(view, "#mockup-viewer-header-count") == "Image 1 of 3"
    end

    test "10. mockup wins over image when both are on the URL", %{conn: conn, board: board, card: card, i1: i1} do
      {:ok, m} =
        Attachments.create_attachment(card, %{
          filename: "m.html",
          content_type: Schemas.Attachment.html_type(),
          bytes: "<p>m</p>"
        })

      {:ok, _card} = Cards.set_mockups(card, [%{"url" => src(m.id), "caption" => "M"}])

      view = open(conn, ~p"/board/#{board.slug}?card=MY1&mockup=#{m.id}&image=#{i1.id}")

      assert text(view, "#mockup-viewer-title") == "Mockups"
      assert has_element?(view, ~s|iframe#mockup-viewer-frame[src="#{src(m.id)}"]|)
    end

    test "11. on the native card host a thumbnail opens the viewer there", %{conn: conn, board: board, n1: n1, i2: i2} do
      view = open(conn, ~p"/cards/MY1?board=#{board.slug}&embed=1")

      view |> element("#timeline-comment-#{n1.id}-images-#{i2.id}") |> render_click()

      assert_patch(view, ~p"/cards/MY1?board=#{board.slug}&image=#{i2.id}")
      assert has_element?(view, ~s|#mockup-viewer-image[src="#{src(i2.id)}"]|)
    end
  end

  describe "9. an id that is not one of the card's note images falls back to the drawer" do
    setup :two_notes

    defp assert_falls_back(conn, board, id) do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1&image=#{id}")
      render_async(view)

      assert_patch(view, ~p"/board/#{board.slug}?card=MY1")
      assert has_element?(view, "#card-drawer")
      refute has_element?(view, "#mockup-viewer")
    end

    test "(a) an unknown id", %{conn: conn, board: board} do
      assert_falls_back(conn, board, Ecto.UUID.generate())
    end

    test "(b) a malformed id", %{conn: conn, board: board} do
      assert_falls_back(conn, board, "not-a-uuid")
    end

    test "(c) an unlinked image on the card", %{conn: conn, board: board, card: card} do
      assert_falls_back(conn, board, image(card, "unposted.png").id)
    end

    test "(d) a mockup attachment on the card", %{conn: conn, board: board, card: card} do
      m = image(card, "mockup.png")
      {:ok, _card} = Cards.set_mockups(card, [%{"url" => src(m.id), "caption" => "M"}])

      assert_falls_back(conn, board, m.id)
    end

    test "(e) a note image on another card", %{conn: conn, board: board, code: code, user: user} do
      {:ok, other} = Cards.create_card(code, %{title: "Other"})
      foreign = image(other, "foreign.png")
      note(other, user, "elsewhere", [foreign])

      assert_falls_back(conn, board, foreign.id)
    end
  end
end
