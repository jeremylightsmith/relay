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
end
