defmodule RelayWeb.BoardLiveWipMoveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Repo
  alias Schemas.Card

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    %{board: board, spec: stage_named(board, "Spec"), code: stage_named(board, "Code")}
  end

  defp stage_named(board, name), do: Enum.find(board.stages, &(&1.name == name))

  describe "soft over-WIP warning on move" do
    test "moving into an at-limit stage still succeeds and warns the acting session",
         %{conn: conn, spec: spec, code: code, user: user} do
      {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 3})
      for n <- 1..3, do: {:ok, _card} = Cards.create_card(code, %{title: "Busy #{n}"})
      {:ok, card} = Cards.create_card(spec, %{title: "One more"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      render_hook(view, "move_card", %{"ref" => "RLY-4", "stage_id" => code.id, "index" => 0})

      assert has_element?(view, "#stage-col-4-cards .board-card", "One more")
      assert Repo.get!(Card, card.id).stage_id == code.id
      assert has_element?(view, "#flash-error", "Code is over its WIP limit — 4/3")
      assert has_element?(view, "#stage-col-4 .stage-wip[data-over]", "wip 4/3")
    end

    test "moving into a stage below its limit does not warn", %{conn: conn, spec: spec, code: code, user: user} do
      {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 3})
      {:ok, _card} = Cards.create_card(code, %{title: "Busy"})
      {:ok, _card} = Cards.create_card(spec, %{title: "Fits fine"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      render_hook(view, "move_card", %{"ref" => "RLY-2", "stage_id" => code.id, "index" => 0})

      assert has_element?(view, "#stage-col-4-cards .board-card", "Fits fine")
      refute has_element?(view, "#flash-error")
      assert has_element?(view, "#stage-col-4 .stage-wip", "wip 2/3")
    end

    test "reordering within an already over-limit stage does not warn", %{conn: conn, code: code, user: user} do
      {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 1})
      {:ok, _card} = Cards.create_card(code, %{title: "First"})
      {:ok, _card} = Cards.create_card(code, %{title: "Second"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      render_hook(view, "move_card", %{"ref" => "RLY-2", "stage_id" => code.id, "index" => 0})

      refute has_element?(view, "#flash-error")
      assert has_element?(view, "#stage-col-4 .stage-wip[data-over]", "wip 2/1")
    end

    test "moving into an unlimited stage never warns", %{conn: conn, spec: spec, code: code, user: user} do
      for n <- 1..3, do: {:ok, _card} = Cards.create_card(code, %{title: "Busy #{n}"})
      {:ok, _card} = Cards.create_card(spec, %{title: "Free flow"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      render_hook(view, "move_card", %{"ref" => "RLY-4", "stage_id" => code.id, "index" => 0})

      assert has_element?(view, "#stage-col-4-cards .board-card", "Free flow")
      refute has_element?(view, "#flash-error")
    end

    test "moving into a Review sub-lane that pushes the parent over its limit warns",
         %{conn: conn, spec: spec, code: code, user: user} do
      {:ok, review} = Boards.enable_lane(code, :review)
      {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 2})
      for n <- 1..2, do: {:ok, _card} = Cards.create_card(code, %{title: "Busy #{n}"})
      {:ok, card} = Cards.create_card(spec, %{title: "Spilling over"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      # RLY-1, RLY-2 are the Code cards; RLY-3 is the Spec card being moved.
      render_hook(view, "move_card", %{"ref" => "RLY-3", "stage_id" => review.id, "index" => 0})

      assert Repo.get!(Card, card.id).stage_id == review.id
      assert has_element?(view, "#flash-error", "Code is over its WIP limit — 3/2")
      assert has_element?(view, "#stage-col-4 .stage-wip[data-over]", "wip 3/2")
    end
  end
end
