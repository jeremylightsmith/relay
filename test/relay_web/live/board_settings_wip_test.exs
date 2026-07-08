defmodule RelayWeb.BoardSettingsWipTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  defp stage_named(board, name), do: Enum.find(board.stages, &(&1.name == name))

  describe "the stage card's WIP control" do
    test "renders Off with no stepper when the stage has no limit", %{conn: conn, board: board} do
      code = stage_named(board, "Code")

      {:ok, view, _html} = live(conn, ~p"/board/settings")

      assert has_element?(view, "#stage-#{code.id}-wip-toggle", "Off")
      refute has_element?(view, "#stage-#{code.id}-wip-value")
    end

    test "toggling on defaults the limit to 3", %{conn: conn, board: board} do
      code = stage_named(board, "Code")

      {:ok, view, _html} = live(conn, ~p"/board/settings")
      view |> element("#stage-#{code.id}-wip-toggle") |> render_click()

      assert has_element?(view, "#stage-#{code.id}-wip-toggle", "On")
      assert has_element?(view, "#stage-#{code.id}-wip-value", "3")
      assert Boards.get_stage(board, code.id).wip_limit == 3
    end

    test "toggling off clears the limit and hides the stepper", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 3})

      {:ok, view, _html} = live(conn, ~p"/board/settings")
      view |> element("#stage-#{code.id}-wip-toggle") |> render_click()

      assert has_element?(view, "#stage-#{code.id}-wip-toggle", "Off")
      refute has_element?(view, "#stage-#{code.id}-wip-value")
      assert Boards.get_stage(board, code.id).wip_limit == nil
    end

    test "the stepper increments, decrements, and floors at 1", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 2})

      {:ok, view, _html} = live(conn, ~p"/board/settings")

      view |> element("#stage-#{code.id}-wip-up") |> render_click()
      assert has_element?(view, "#stage-#{code.id}-wip-value", "3")
      assert Boards.get_stage(board, code.id).wip_limit == 3

      view |> element("#stage-#{code.id}-wip-down") |> render_click()
      view |> element("#stage-#{code.id}-wip-down") |> render_click()
      assert has_element?(view, "#stage-#{code.id}-wip-value", "1")

      view |> element("#stage-#{code.id}-wip-down") |> render_click()
      assert has_element?(view, "#stage-#{code.id}-wip-value", "1")
      assert Boards.get_stage(board, code.id).wip_limit == 1
    end

    test "toggling off hides the chip on an open board via the broadcast",
         %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 3})
      {:ok, _card} = Cards.create_card(code, %{title: "Busy"})

      {:ok, board_view, _html} = live(conn, ~p"/board")
      assert has_element?(board_view, "#stage-col-4 .stage-wip", "wip 1/3")

      {:ok, settings_view, _html} = live(conn, ~p"/board/settings")
      settings_view |> element("#stage-#{code.id}-wip-toggle") |> render_click()

      render(board_view)
      refute has_element?(board_view, ".stage-wip")
    end
  end
end
