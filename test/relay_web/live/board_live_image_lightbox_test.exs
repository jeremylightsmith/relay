defmodule RelayWeb.BoardLiveImageLightboxTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Attachments
  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    %{board: board, code: code}
  end

  describe "the shared image lightbox" do
    test "the board page renders the lightbox dialog", %{conn: conn, board: board} do
      # The dialog is rendered once in root.html.heex, as a sibling of the LiveView's own
      # content — so it's outside the tracked subtree `has_element?(view, ...)` inspects
      # (Phoenix.LiveViewTest.render/1: "the entire LiveView is rendered", not the root
      # layout around it). Assert on the connected mount's full HTML instead, which is what
      # a real browser receives on page load.
      {:ok, _view, html} = live(conn, ~p"/board/#{board.slug}")

      assert html =~ ~s(id="image-lightbox")
      assert html =~ ~s(id="image-lightbox-img")
      assert html =~ "modal-backdrop"
    end

    test "a dead controller page renders it too, so docs images are clickable",
         %{conn: conn} do
      html = conn |> get(~p"/privacy") |> html_response(200)

      assert html =~ ~s(id="image-lightbox")
      assert html =~ ~s(id="image-lightbox-img")
    end

    test "the root-layout dialog carries the RE322 carousel controls", %{conn: conn, board: board} do
      # Root layout, outside the LiveView's tracked subtree — assert on the mount HTML (see above).
      {:ok, _view, html} = live(conn, ~p"/board/#{board.slug}")
      doc = LazyHTML.from_document(html)

      for id <- ~w(image-lightbox-prev image-lightbox-next image-lightbox-counter image-lightbox-caption) do
        assert doc |> LazyHTML.query("dialog#image-lightbox ##{id}") |> Enum.count() == 1, "missing ##{id}"
      end
    end
  end

  # RE390 — AI Result screenshots left the lightbox: they are 80px tiles patching to the
  # same-tab viewer (`?screenshot=<n>`), drawn by the attachment's content type.
  describe "AI Result screenshot tiles" do
    test "an uploaded image screenshot is a tile patching to ?screenshot=1, with no zoom-in affordance",
         %{conn: conn, board: board, code: code} do
      {:ok, card} = Cards.create_card(code, %{title: "Shipped it"})

      {:ok, attachment} =
        Attachments.create_attachment(card, %{filename: "board.png", content_type: "image/png", bytes: "png"})

      {:ok, _card} =
        Cards.update_ai_result(card, %{
          "summary" => "Done",
          "screens" => [%{"url" => "/attachments/#{attachment.id}", "caption" => "Board"}]
        })

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
      render_async(view)

      assert has_element?(
               view,
               ~s(a#ai-result-screen-0-open[href="/board/#{board.slug}?card=MY1&screenshot=1"] img[src="/attachments/#{attachment.id}"])
             )

      refute has_element?(view, "#ai-result-screens .cursor-zoom-in")
    end
  end
end
