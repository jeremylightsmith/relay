defmodule RelayWeb.BoardLiveCollapseTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    %{board: board, code: Enum.find(board.stages, &(&1.name == "Code"))}
  end

  describe "sub-lane collapse toggle (item 2)" do
    test "clicking a non-empty sub-lane header collapses it, and the strip re-expands it",
         %{conn: conn, code: code, user: user} do
      {:ok, done} = Boards.enable_lane(code, :done)
      {:ok, card} = Cards.create_card(code, %{title: "Shipit"})
      {:ok, _moved} = Cards.move_card(card, done, 0)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      # non-empty → renders expanded (cards container), not the strip
      assert has_element?(view, "#sublane-#{done.id}-cards")
      refute has_element?(view, "#sublane-#{done.id}-strip")

      view |> element("#sublane-#{done.id}-header") |> render_click()
      assert has_element?(view, "#sublane-#{done.id}-strip")

      view |> element("#sublane-#{done.id}-strip") |> render_click()
      assert has_element?(view, "#sublane-#{done.id}-cards")
      refute has_element?(view, "#sublane-#{done.id}-strip")
    end
  end

  describe "main lane collapse toggle (item 3)" do
    test "clicking the In progress header collapses the main lane to a strip, and back",
         %{conn: conn, code: code, user: user} do
      {:ok, _done} = Boards.enable_lane(code, :done)
      {:ok, _card} = Cards.create_card(code, %{title: "WIP"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-col-5-main-lane-header")
      refute has_element?(view, "#stage-col-5-main-strip")

      view |> element("#stage-col-5-main-lane-header") |> render_click()
      assert has_element?(view, "#stage-col-5-main-strip")

      view |> element("#stage-col-5-main-strip") |> render_click()
      refute has_element?(view, "#stage-col-5-main-strip")
      assert has_element?(view, "#stage-col-5-main-lane-header")
    end
  end
end
