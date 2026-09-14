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
end
