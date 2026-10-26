defmodule RelayWeb.BoardSettingsPublicTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards

  setup %{conn: conn} do
    user = insert(:user)
    board = Boards.get_or_create_default_board(user)
    %{conn: log_in_user(conn, user), board: board}
  end

  test "enabling shows the URL row + intake picker and persists", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=public")

    refute has_element?(view, "#public-url-row")

    view
    |> element("#public-settings-form")
    |> render_change(%{"board" => %{"public_enabled" => "true"}})

    assert has_element?(view, "#public-url-row", "/board/#{board.slug}/public")
    assert has_element?(view, "#intake-stage-picker")
    assert Boards.get_public_board(board.slug) != :error
  end

  test "the URL row uses the field-surface token, not the base-200 canvas token", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=public")

    view
    |> element("#public-settings-form")
    |> render_change(%{"board" => %{"public_enabled" => "true"}})

    assert has_element?(view, "#public-url-row[style*='background:var(--color-field-bg)']")
  end

  # RE480 scenario 4
  test "the public URL follows the configured host, not the request's", %{conn: conn, board: board} do
    {:ok, view, _html} = live(%{conn | host: "relayboard.fly.dev"}, ~p"/board/#{board.slug}/settings?section=public")

    view
    |> element("#public-settings-form")
    |> render_change(%{"board" => %{"public_enabled" => "true"}})

    text = view |> element("#public-url-row") |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()
    assert text == "#{RelayWeb.Endpoint.url()}/board/#{board.slug}/public"
  end
end
