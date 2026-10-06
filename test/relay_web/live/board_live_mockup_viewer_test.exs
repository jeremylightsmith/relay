defmodule RelayWeb.BoardLiveMockupViewerTest do
  @moduledoc """
  RE380 — BoardLive's viewer mode: `?card=<ref>&mockup=<id>` opens the card's mockup in the same
  tab, the mockup on the right and the card as a left sheet carrying its gate panel and the
  Mockups tiles. Switching mockups is a replace patch that keeps the sheet's state; Back/Esc
  return to the drawer; a stale or foreign id falls back to the drawer.
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
    code = Enum.find(board.stages, &(&1.name == "Code"))
    plan = Enum.find(board.stages, &(&1.name == "Plan"))
    review = Enum.find(board.stages, &(&1.name == "Review"))
    deploy = Enum.find(board.stages, &(&1.name == "Deploy"))

    card = in_review_card(review)
    [m1, m2, m3] = mockups = for name <- ~w(a b c), do: upload(card, "#{name}.html")
    {:ok, card} = Cards.set_mockups(card, entries(mockups))

    %{board: board, card: card, code: code, plan: plan, review: review, deploy: deploy, m1: m1, m2: m2, m3: m3}
  end

  @captions ["A — one list", "B — two panes", "C — empty"]

  defp in_review_card(stage, title \\ "Review me") do
    {:ok, card} = Cards.create_card(stage, %{title: title})
    {:ok, card} = Cards.set_status(card, %{status: :in_review})
    card
  end

  defp upload(card, name) do
    {:ok, attachment} =
      Attachments.create_attachment(card, %{
        filename: name,
        content_type: Schemas.Attachment.html_type(),
        bytes: "<p>#{name}</p>"
      })

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

  defp viewer(conn, board, mockup), do: open(conn, ~p"/board/#{board.slug}?card=MY1&mockup=#{mockup.id}")

  # LiveViewTest has `refute_redirected/1` but no patch counterpart; a push_patch lands in the
  # test process as this message, so its absence is "no patch happened".
  defp refute_patched(%{proxy: {ref, topic, _}}), do: refute_received({^ref, {:patch, ^topic, _}})

  defp header_caption(view), do: view |> element("#mockup-viewer-header-caption") |> render() |> text()

  defp header_count(view), do: view |> element("#mockup-viewer-header-count") |> render() |> text()

  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  test "1. a drawer tile opens the viewer in the same tab", %{conn: conn, board: board, m1: m1} do
    view = open(conn, ~p"/board/#{board.slug}?card=MY1")

    view |> element("#card-drawer-mockup-0-open") |> render_click()

    assert_patch(view, ~p"/board/#{board.slug}?card=MY1&mockup=#{m1.id}")
    assert has_element?(view, "#mockup-viewer")

    assert has_element?(
             view,
             ~s|iframe#mockup-viewer-frame[src="#{RelayWeb.attachment_path(m1.id)}"][sandbox="allow-scripts"]|
           )

    assert has_element?(view, ~s|#mockup-viewer-mockup-0-open[aria-current="true"]|)
    assert header_caption(view) == "A — one list"
    assert header_count(view) == "1 of 3"
    refute has_element?(view, "#mockup-viewer-mockups-viewing")
    refute has_element?(view, "#mockup-viewer-mockups-keys")
    refute render(view) =~ ~s(target="_blank")
  end

  test "2. tiles and → switch mockups with replace patches", %{conn: conn, board: board, m1: m1, m2: m2, m3: m3} do
    view = viewer(conn, board, m1)

    view |> element("#mockup-viewer-mockup-1-open") |> render_click()
    assert_patch(view, ~p"/board/#{board.slug}?card=MY1&mockup=#{m2.id}")
    assert has_element?(view, ~s|#mockup-viewer-mockup-1-open[aria-current="true"]|)
    assert header_caption(view) == "B — two panes"
    assert header_count(view) == "2 of 3"

    view |> element("#mockup-viewer-key-next") |> render_keydown(%{"key" => "ArrowRight"})
    assert_patch(view, ~p"/board/#{board.slug}?card=MY1&mockup=#{m3.id}")
    assert header_caption(view) == "C — empty"
    assert header_count(view) == "3 of 3"
  end

  test "3. ← / → stop at the ends", %{conn: conn, board: board, m1: m1, m3: m3} do
    view = viewer(conn, board, m3)
    render_hook(view, "mockup_next", %{})
    refute_patched(view)
    assert header_count(view) == "3 of 3"

    view = viewer(conn, board, m1)
    render_hook(view, "mockup_prev", %{})
    refute_patched(view)
    assert header_count(view) == "1 of 3"
  end

  # RE393 — the embed-only nav bar, width toggle and pager never reach the web board viewer.
  test "6. the non-embed viewer keeps the one-bar header: no pager, no width toggle",
       %{conn: conn, board: board, card: card, m1: m1, m2: m2} do
    {:ok, _card} = Cards.set_mockups(card, entries([m1, m2]))

    view = viewer(conn, board, m1)

    assert view |> element("#mockup-viewer-bar-count") |> render() |> text() == "1 / 2"
    refute has_element?(view, "#mockup-viewer-pager")
    refute has_element?(view, "#mockup-viewer-width")
    refute has_element?(view, "#mockup-viewer-zoom")
    refute has_element?(view, "#mockup-viewer-frame-sizer")
    refute has_element?(view, "#mockup-viewer-native")
  end

  defp open_reject_with_note(view, note) do
    view |> element("#review-request-changes") |> render_click()
    view |> element("#review-reject-form") |> render_change(%{"reject" => %{"note" => note}})
  end

  test "4. the reject note survives switching mockups and the quote follows the current mockup",
       %{conn: conn, board: board, m1: m1} do
    view = viewer(conn, board, m1)
    open_reject_with_note(view, "keep the filter")

    view |> element("#mockup-viewer-mockup-1-open") |> render_click()

    assert has_element?(view, "#review-reject-panel")
    assert has_element?(view, "#review-request-note", "keep the filter")
    assert view |> element("#review-quote-caption") |> render() |> text() == "+ Quote “B — two panes”"
  end

  test "5. Back to card returns to the drawer with the note intact", %{conn: conn, board: board, m1: m1} do
    view = viewer(conn, board, m1)
    open_reject_with_note(view, "keep the filter")
    view |> element("#mockup-viewer-mockup-1-open") |> render_click()

    view |> element("#mockup-viewer-back") |> render_click()

    assert_patch(view, ~p"/board/#{board.slug}?card=MY1")
    refute has_element?(view, "#mockup-viewer")
    assert has_element?(view, "#card-drawer")
    refute has_element?(view, "#card-drawer.hidden")
    assert has_element?(view, "#card-drawer #review-request-note", "keep the filter")
  end

  test "6. Esc (mockup_back) returns to the drawer", %{conn: conn, board: board, m2: m2} do
    view = viewer(conn, board, m2)

    render_hook(view, "mockup_back", %{})

    assert_patch(view, ~p"/board/#{board.slug}?card=MY1")
    refute has_element?(view, "#mockup-viewer")
  end

  test "7. a cold open (reload / shared link) shows the named mockup", %{conn: conn, board: board, m2: m2} do
    view = viewer(conn, board, m2)

    assert has_element?(view, ~s|iframe#mockup-viewer-frame[src="#{RelayWeb.attachment_path(m2.id)}"]|)
    assert view |> element("#top-bar-crumb-card") |> render() |> text() == "Review me"
  end

  describe "8. an id that is not one of the card's mockups falls back to the drawer" do
    defp assert_falls_back(conn, board, id) do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1&mockup=#{id}")
      render_async(view)

      assert_patch(view, ~p"/board/#{board.slug}?card=MY1")
      assert has_element?(view, "#card-drawer")
      refute has_element?(view, "#mockup-viewer")
    end

    test "an unknown id", %{conn: conn, board: board} do
      assert_falls_back(conn, board, Ecto.UUID.generate())
    end

    test "a non-mockup HTML attachment on the card", %{conn: conn, board: board, card: card} do
      other = upload(card, "notes.html")
      assert_falls_back(conn, board, other.id)
    end

    test "another card's mockup", %{conn: conn, board: board, code: code} do
      {:ok, other_card} = Cards.create_card(code, %{title: "Other"})
      other = upload(other_card, "x.html")
      {:ok, _} = Cards.set_mockups(other_card, [%{"url" => RelayWeb.attachment_path(other.id), "caption" => "X"}])

      assert_falls_back(conn, board, other.id)
    end
  end

  test "9. a mockup removed while on screen falls back to the drawer",
       %{conn: conn, board: board, card: card, m1: m1, m2: m2, m3: m3} do
    view = viewer(conn, board, m3)

    {:ok, _card} = Cards.set_mockups(card, entries([m1, m2]))

    assert_patch(view, ~p"/board/#{board.slug}?card=MY1")
    refute has_element?(view, "#mockup-viewer")
  end

  test "10. the top bar is the breadcrumb trail ending in Mockups", %{conn: conn, board: board, m1: m1} do
    view = viewer(conn, board, m1)

    assert has_element?(view, "#top-bar-crumb-boards")
    assert has_element?(view, ~s|#top-bar-crumb-board[href="/board/#{board.slug}"]|, board.name)

    assert has_element?(
             view,
             ~s|#top-bar-crumb-card[href="/board/#{board.slug}?card=MY1"][data-phx-link="patch"]|
           )

    assert view |> element("#top-bar-crumb-card") |> render() |> text() == "Review me"
    assert view |> element("#mockup-viewer-title") |> render() |> text() == "Mockups"

    for id <- ~w(#board-name #board-view-tabs #agent-logs-button #board-settings-link #mockup-viewer-banner) do
      refute has_element?(view, id), "#{id} should not render in viewer mode"
    end
  end

  test "11. the drawer stays mounted but hidden, inert, and without its gate panel",
       %{conn: conn, board: board, m1: m1} do
    view = viewer(conn, board, m1)

    assert has_element?(view, "#card-drawer.hidden")
    refute has_element?(view, "#card-drawer[phx-window-keydown]")
    assert has_element?(view, "#mockup-viewer-sheet #review-panel")

    assert view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#review-panel") |> Enum.count() == 1

    refute has_element?(view, "#card-drawer-prev")
    refute has_element?(view, "#card-drawer-next")
  end

  test "12. Approve from the sheet dispatches the card and returns to the board",
       %{conn: conn, board: board, deploy: deploy, m1: m1} do
    view = viewer(conn, board, m1)

    assert view |> element("#review-approve .pending-idle") |> render() |> text() == "Approve"
    view |> element("#review-approve") |> render_click()

    assert_patch(view, ~p"/board/#{board.slug}")
    refute has_element?(view, "#mockup-viewer")
    refute has_element?(view, "#card-drawer")

    reloaded = Cards.get_card_by_ref(board, "MY1")
    assert reloaded.stage_id == deploy.id
    assert reloaded.status == :working
  end

  test "12b. Approve from the sheet advances to the next card awaiting review (RE388)",
       %{conn: conn, board: board, review: review, m1: m1} do
    # created after MY1, so it lands at the TOP of Review — MY1 is now the bottom card
    in_review_card(review, "Second")
    view = viewer(conn, board, m1)

    view |> element("#review-approve") |> render_click()

    assert_patch(view, ~p"/board/#{board.slug}?card=MY2")
    render_async(view)

    refute has_element?(view, "#mockup-viewer")
    assert has_element?(view, "#card-drawer", "Second")
    assert has_element?(view, "#flash-info", "Approved MY1 → Deploy")
  end

  test "13. Reject from the sheet sends the card back with the note", %{conn: conn, board: board, plan: plan, m1: m1} do
    view = viewer(conn, board, m1)
    view |> element("#review-request-changes") |> render_click()

    view |> form("#review-reject-form", reject: %{note: "Use B's grouping"}) |> render_submit()

    assert_patch(view, ~p"/board/#{board.slug}")

    reloaded = Cards.get_card_by_ref(board, "MY1")
    assert reloaded.stage_id == plan.id

    assert Enum.any?(
             Activity.list_timeline(reloaded),
             &match?(%Schemas.Activity{type: :rejected, meta: %{"note" => "Use B's grouping"}}, &1)
           )
  end

  test "14. a card waiting on you shows its question in the sheet", %{conn: conn, board: board, code: code} do
    {:ok, card} = Cards.create_card(code, %{title: "Pick one"})
    [m1 | _] = mockups = for name <- ~w(a b c), do: upload(card, "#{name}.html")
    {:ok, card} = Cards.set_mockups(card, entries(mockups))

    {:ok, card} =
      Cards.request_input(card, [%{"prompt" => "Which layout wins?", "options" => ["A", "B"], "allow_text" => true}])

    view = open(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}&mockup=#{m1.id}")

    assert has_element?(view, "#mockup-viewer-sheet #needs-input-panel", "Which layout wins?")
    refute has_element?(view, "#review-panel")
  end

  test "15. the story map hosts the viewer and Back returns to the map's drawer",
       %{conn: conn, board: board, m1: m1} do
    view = open(conn, ~p"/board/#{board.slug}/story-map?card=MY1&mockup=#{m1.id}")

    assert has_element?(view, "#mockup-viewer")

    view |> element("#mockup-viewer-back") |> render_click()
    assert_patch(view, ~p"/board/#{board.slug}/story-map?card=MY1")
  end

  test "17. a same-card mockup patch does not reset the drawer; a card switch still does",
       %{conn: conn, board: board, review: review, m1: m1} do
    in_review_card(review, "Second")
    view = open(conn, ~p"/board/#{board.slug}?card=MY1")

    entry_ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#card-drawer-activity > li.activity-entry")
      |> LazyHTML.attribute("id")

    assert entry_ids != []

    # Drawer state assign_selected_card/2 (and its async fill) would reset to the Detail tab.
    view |> element("#card-drawer-tab-activity") |> render_click()
    assert has_element?(view, "#card-drawer-tab-activity[data-active='true']")

    view |> element("#card-drawer-mockup-0-open") |> render_click()
    assert_patch(view, ~p"/board/#{board.slug}?card=MY1&mockup=#{m1.id}")
    view |> element("#mockup-viewer-back") |> render_click()
    assert_patch(view, ~p"/board/#{board.slug}?card=MY1")

    # No render_async: a re-run of assign_selected_card/2 would leave the body loading and the
    # activity stream emptied until the async fill lands.
    for id <- entry_ids, do: assert(has_element?(view, "#card-drawer-activity > ##{id}"))
    render_async(view)
    assert has_element?(view, "#card-drawer-tab-activity[data-active='true']")

    view |> element("#review-request-changes") |> render_click()
    assert has_element?(view, "#review-reject-panel")

    render_patch(view, ~p"/board/#{board.slug}?card=MY2")
    render_async(view)
    refute has_element?(view, "#review-reject-panel")
  end

  test "18. a URL with both mockup= and screenshot= opens the mockup", %{conn: conn, board: board, card: card, m1: m1} do
    shot = upload(card, "shot.html")
    {:ok, _card} = Cards.update_ai_result(card, %{"screens" => [%{"url" => RelayWeb.attachment_path(shot.id)}]})

    view = open(conn, ~p"/board/#{board.slug}?card=MY1&mockup=#{m1.id}&screenshot=1")

    assert has_element?(view, ~s|iframe#mockup-viewer-frame[src="#{RelayWeb.attachment_path(m1.id)}"]|)
    assert view |> element("#mockup-viewer-title") |> render() |> text() == "Mockups"
    assert header_caption(view) == "A — one list"
    assert header_count(view) == "1 of 3"
  end

  test "19. an image mockup shows at natural size in a scrolling frame", %{conn: conn, board: board, card: card} do
    {:ok, png} =
      Attachments.create_attachment(card, %{filename: "shot.png", content_type: "image/png", bytes: "png bytes"})

    {:ok, _card} = Cards.set_mockups(card, [%{"url" => RelayWeb.attachment_path(png.id), "caption" => "Shot"}])

    view = open(conn, ~p"/board/#{board.slug}?card=MY1&mockup=#{png.id}")

    assert has_element?(
             view,
             ~s|#mockup-viewer-frame-box-#{png.id}.overflow-auto #mockup-viewer-image[src="#{RelayWeb.attachment_path(png.id)}"]|
           )

    assert has_element?(view, "#card-drawer-mockup-0-open img.object-top")
  end
end
