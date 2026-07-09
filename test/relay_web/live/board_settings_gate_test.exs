defmodule RelayWeb.BoardSettingsGateTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  defp stage_named(board, name), do: Enum.find(board.stages, &(&1.name == name))

  describe "the stage card's APPROVAL GATE controls" do
    test "renders the gate toggle off with no reject select by default", %{conn: conn, board: board} do
      review = stage_named(board, "Review")

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      assert has_element?(view, "#stage-#{review.id}-gate-toggle")
      refute has_element?(view, "#stage-#{review.id}-gate-toggle[checked]")
      refute has_element?(view, "#stage-#{review.id}-reject-target")
    end

    test "toggling the gate on persists and reveals the reject select", %{conn: conn, board: board} do
      review = stage_named(board, "Review")

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")
      view |> element("#stage-#{review.id}-gate-toggle") |> render_click()

      assert has_element?(view, "#stage-#{review.id}-gate-toggle[checked]")
      assert has_element?(view, "#stage-#{review.id}-reject-target")
      assert Boards.get_stage(board, review.id).approval_gate
    end

    test "toggling the gate off persists and clears the reject target", %{conn: conn, board: board} do
      review = stage_named(board, "Review")
      code = stage_named(board, "Code")
      {:ok, _stage} = Boards.update_stage(review, %{approval_gate: true, reject_to_stage_id: code.id})

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")
      view |> element("#stage-#{review.id}-gate-toggle") |> render_click()

      refute has_element?(view, "#stage-#{review.id}-reject-target")
      reloaded = Boards.get_stage(board, review.id)
      refute reloaded.approval_gate
      assert reloaded.reject_to_stage_id == nil
    end

    test "the reject select lists This stage plus only the other main stages", %{conn: conn, board: board} do
      review = stage_named(board, "Review")
      code = stage_named(board, "Code")
      {:ok, _stage} = Boards.update_stage(review, %{approval_gate: true})
      {:ok, sublane} = Boards.enable_lane(code, :review)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      assert has_element?(view, "#stage-#{review.id}-reject-target option[value='']", "This stage")
      assert has_element?(view, "#stage-#{review.id}-reject-target option[value='#{code.id}']", "Code")
      refute has_element?(view, "#stage-#{review.id}-reject-target option[value='#{review.id}']")
      refute has_element?(view, "#stage-#{review.id}-reject-target option[value='#{sublane.id}']")
    end

    test "picking a reject target persists it and rejected cards route there", %{conn: conn, board: board} do
      review = stage_named(board, "Review")
      code = stage_named(board, "Code")
      {:ok, _stage} = Boards.update_stage(review, %{approval_gate: true})

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      view
      |> element("#stage-#{review.id}-reject-form")
      |> render_change(%{"reject_to_stage_id" => to_string(code.id)})

      assert Boards.get_stage(board, review.id).reject_to_stage_id == code.id

      {:ok, card} = Cards.create_card(review, %{title: "Gated work"})
      {:ok, rejected} = Cards.reject(card, "Needs edge cases")
      assert rejected.stage_id == code.id
    end
  end
end
