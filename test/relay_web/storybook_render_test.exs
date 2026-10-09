defmodule RelayWeb.StorybookRenderTest do
  @moduledoc """
  Every storybook story page must render without raising. A stale fixture or a
  component-contract drift (RLY-59: card_drawer's review_gate lost reject_target_name)
  otherwise 500s only when a human opens that specific page — this guards the whole set.
  """
  use RelayWeb.ConnCase, async: true

  for %{path: path} <- RelayWeb.Storybook.leaves() do
    @story_path path

    test "GET /storybook#{path} renders", %{conn: conn} do
      conn = get(conn, "/storybook" <> @story_path)
      assert html_response(conn, 200)
    end
  end

  test "GET /storybook/core_components/card_drawer shows the Notes count and the :question state (RE277)",
       %{conn: conn} do
    conn = get(conn, "/storybook/core_components/card_drawer")
    html = html_response(conn, 200)

    assert html =~ "3 notes"
    assert html =~ "QUESTION"
  end

  test "GET /storybook/core_components/mockup_preview shows the RE374 tiles in a wrapping row", %{conn: conn} do
    html = conn |> get("/storybook/core_components/mockup_preview") |> html_response(200)
    doc = LazyHTML.from_document(html)

    assert doc |> LazyHTML.query(".flex.flex-wrap.gap-2 a[id^='mockup-preview-wrapping-row-tile-']") |> Enum.count() == 5

    # The fifth tile has no caption, so it falls back to "Mockup".
    assert doc
           |> LazyHTML.query("a#mockup-preview-wrapping-row-tile-4-open[aria-label='Open mockup: Mockup']")
           |> Enum.count() == 1

    assert html =~ "80px square live miniature"
  end

  test "GET the RE380 review panel, Mockups section and mobile viewer bar stories", %{conn: conn} do
    for page <- ~w(card_review_panel card_mockups_section mockup_viewer_bar) do
      assert conn |> get("/storybook/core_components/#{page}") |> html_response(200)
    end

    html = conn |> get("/storybook/core_components/card_mockups_section") |> html_response(200)
    assert html =~ ~s(aria-current="true")
  end

  test "GET the RE427 note image row story", %{conn: conn} do
    doc = conn |> get("/storybook/core_components/note_image_row") |> html_response(200) |> LazyHTML.from_document()

    assert doc |> LazyHTML.query("#note-image-row-single-two-images a img.h-\\[108px\\]") |> Enum.count() == 2
    assert doc |> LazyHTML.query("#note-image-row-single-single-wide a img.max-w-\\[240px\\]") |> Enum.count() == 1
  end

  test "GET the RE427 image control story renders each state", %{conn: conn} do
    html = conn |> get("/storybook/core_components/image_attach_box") |> html_response(200)
    doc = LazyHTML.from_document(html)

    assert html =~ "Uploading…"
    assert html =~ "Drop to attach"
    assert html =~ "the most one note can carry"
    assert html =~ "isn’t an image"
    assert html =~ "the limit is 5 MB"
    assert doc |> LazyHTML.query(".phx-drop-target-active") |> Enum.count() >= 1
    assert doc |> LazyHTML.query("[id$='-pending'] img") |> Enum.count() >= 2
  end

  test "GET the RE390 image tile, Screenshots section and media placeholder stories", %{conn: conn} do
    placeholder = conn |> get("/storybook/core_components/media_placeholder") |> html_response(200)
    assert placeholder |> LazyHTML.from_document() |> LazyHTML.query("span.border-dashed.size-20") |> Enum.count() >= 1

    for page <- ~w(mockup_preview card_mockups_section) do
      doc = conn |> get("/storybook/core_components/#{page}") |> html_response(200) |> LazyHTML.from_document()
      assert doc |> LazyHTML.query("a img.object-top") |> Enum.count() >= 1, "#{page}: no image tile"
    end

    section = conn |> get("/storybook/core_components/card_mockups_section") |> html_response(200)
    assert section |> LazyHTML.from_document() |> LazyHTML.query("span.border-dashed") |> Enum.count() >= 1
  end

  test "GET /storybook/core_components/stage_column shows the RE377 compact pager page and Show as list",
       %{conn: conn} do
    html = conn |> get("/storybook/core_components/stage_column") |> html_response(200)
    doc = LazyHTML.from_document(html)

    # Storybook rewrites each variation's id to "stage-column-single-<variation>".
    # Collapsed + pager: the compact page — collapsed badge, Show cards, one-line rows.
    assert doc |> LazyHTML.query("#stage-column-single-collapsed-pager-collapsed-badge") |> Enum.count() == 1
    assert doc |> LazyHTML.query("#stage-column-single-collapsed-pager-show-cards") |> Enum.count() == 1
    assert doc |> LazyHTML.query("#stage-column-single-collapsed-pager-rows .compact-card-row") |> Enum.count() == 2

    # The terminal Done stage pages its rows with an "N more" button.
    more = LazyHTML.query(doc, "#stage-column-single-collapsed-pager-done-more-rows-more")
    assert Enum.count(more) == 1
    assert more |> LazyHTML.text() |> String.trim() == "2 more"

    # Expanded in pager mode: Show as list folds it back to rows.
    assert doc |> LazyHTML.query("#stage-column-single-pager-expanded-show-as-list") |> Enum.count() == 1
  end

  test "GET /storybook/core_components/compact_card_row renders the RE377 one-line rows", %{conn: conn} do
    html = conn |> get("/storybook/core_components/compact_card_row") |> html_response(200)
    doc = LazyHTML.from_document(html)

    assert doc |> LazyHTML.query("#compact-card-row-single-long-title-truncates .compact-card-row-title") |> Enum.count() ==
             1

    assert doc |> LazyHTML.query("#compact-card-row-single-done .compact-card-row-dot.bg-success") |> Enum.count() == 1

    assert doc |> LazyHTML.query("#compact-card-row-single-needs-input .compact-card-row-dot.bg-warning") |> Enum.count() ==
             1
  end

  test "GET /storybook/flow_metrics/verdict_bar shows the RE235 actual-counts variations", %{conn: conn} do
    conn = get(conn, "/storybook/flow_metrics/verdict_bar")
    html = html_response(conn, 200)

    assert html =~ "1 ok"
    assert html =~ "2 ok · 1 fail"
    assert html =~ "92% ok · 5% fail"
  end

  test "GET /storybook/core_components/image_lightbox shows the RE322 single and multi-image viewer states",
       %{conn: conn} do
    html = conn |> get("/storybook/core_components/image_lightbox") |> html_response(200)
    doc = LazyHTML.from_document(html)

    # Multi-image: Previous/Next, a 2 / 5 counter and a caption, all visible.
    assert doc |> LazyHTML.query("#image-lightbox-story-multi-prev:not([hidden])") |> Enum.count() == 1
    assert doc |> LazyHTML.query("#image-lightbox-story-multi-next:not([hidden])") |> Enum.count() == 1
    assert doc |> LazyHTML.query("#image-lightbox-story-multi-counter") |> LazyHTML.text() |> String.trim() == "2 / 5"
    assert doc |> LazyHTML.query("#image-lightbox-story-multi-caption:not([hidden])") |> Enum.count() == 1

    # Single image: no nav, no counter.
    assert doc |> LazyHTML.query("#image-lightbox-story-single-prev[hidden]") |> Enum.count() == 1
    assert doc |> LazyHTML.query("#image-lightbox-story-single-counter[hidden]") |> Enum.count() == 1
  end

  test "GET /storybook/core_components/copy_button renders the copy button story (RE324)", %{conn: conn} do
    html = conn |> get("/storybook/core_components/copy_button") |> html_response(200)

    assert html =~ "Copy branch name"
    assert html =~ "re-324-fix-long-links-including-prs-and-this-is-a-very-long-branch-name"
  end

  test "GET /storybook/core_components/breadcrumbs shows the board, settings and deep flow trails (RE334)",
       %{conn: conn} do
    html = conn |> get("/storybook/core_components/breadcrumbs") |> html_response(200)

    assert html =~ "Boards"
    assert html =~ "Payments"
    assert html =~ "Settings"
    assert html =~ "Stages"
    refute html =~ "section=flows"
  end

  test "GET /storybook/flow_settings_components/flow_band renders the band, no-flow and queue variations (RE431)",
       %{conn: conn} do
    html = conn |> get("/storybook/flow_settings_components/flow_band") |> html_response(200)

    assert html =~ "code flow"
    assert html =~ "v4 · 7 nodes"
    assert html =~ "No flow — people work this stage by hand."
    assert html =~ "cards rest here"
  end

  test "GET /storybook/flow_settings_components/stage_neighbours renders the full and missing-end rows (RE431)",
       %{conn: conn} do
    html = conn |> get("/storybook/flow_settings_components/stage_neighbours") |> html_response(200)

    assert html =~ "Plan · Done"
    assert html =~ "worked out from board order"
    assert html =~ "none"
  end

  test "GET /storybook/flow_graph shows the RE333 branching variation — a diverging branch and several terminals",
       %{conn: conn} do
    html = conn |> get("/storybook/flow_graph") |> html_response(200)

    for key <- ~w(triage fix ship write_docs publish escalate) do
      assert html =~ ~s(data-node="#{key}"), "branching variation is missing node #{key}"
    end
  end

  test "GET /storybook/core_components/mobile_nav_bar shows the bridge and patch backs (RE393)", %{conn: conn} do
    doc = conn |> get("/storybook/core_components/mobile_nav_bar") |> html_response(200) |> LazyHTML.from_document()

    assert doc |> LazyHTML.query("button[id$='-back'][phx-hook$='NativeBack']") |> Enum.count() >= 1
    assert doc |> LazyHTML.query("a[id$='-back'][data-phx-link='patch']") |> Enum.count() >= 1
  end

  test "GET /storybook/core_components/segmented_control shows text and icon variants (RE393)", %{conn: conn} do
    doc = conn |> get("/storybook/core_components/segmented_control") |> html_response(200) |> LazyHTML.from_document()

    assert doc |> LazyHTML.query("[role=group] button[data-active=true]") |> Enum.count() >= 2

    assert doc |> LazyHTML.query("[role=group][aria-label] button[aria-label] span.hero-computer-desktop") |> Enum.count() >=
             1
  end

  test "GET /storybook/core_components/mockup_viewer_pager shows the first, middle and last pages (RE393)",
       %{conn: conn} do
    doc = conn |> get("/storybook/core_components/mockup_viewer_pager") |> html_response(200) |> LazyHTML.from_document()

    assert doc |> LazyHTML.query("button[id$='-prev'][disabled]") |> Enum.count() >= 1
    assert doc |> LazyHTML.query("button[id$='-next'][disabled]") |> Enum.count() >= 1
    assert doc |> LazyHTML.query("[id$='-count']") |> LazyHTML.text() =~ "2 of 3"
  end

  test "GET /storybook/core_components/mockup_viewer_zoom shows − disabled, Fit and + (RE393)", %{conn: conn} do
    doc = conn |> get("/storybook/core_components/mockup_viewer_zoom") |> html_response(200) |> LazyHTML.from_document()

    assert doc |> LazyHTML.query("button[id$='-out'][disabled]") |> Enum.count() >= 1
    assert doc |> LazyHTML.query("button[id$='-in']") |> Enum.count() >= 1
    assert doc |> LazyHTML.query("button[id$='-reset']") |> LazyHTML.text() =~ "Fit"
  end
end
