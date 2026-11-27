defmodule Hamaca.BoardsPublicTest do
  use Hamaca.DataCase, async: true

  alias Hamaca.Boards
  alias Schemas.Stage

  describe "update_public_settings/2" do
    test "enables the board and sets a valid intake stage" do
      board = insert(:board)
      stage = insert(:stage, board: board)

      assert {:ok, updated} =
               Boards.update_public_settings(board, %{
                 "public_enabled" => true,
                 "public_intake_stage_id" => stage.id
               })

      assert updated.public_enabled
      assert updated.public_intake_stage_id == stage.id
    end

    test "rejects an intake stage from another board" do
      board = insert(:board)
      foreign = insert(:stage)

      assert {:error, changeset} =
               Boards.update_public_settings(board, %{"public_intake_stage_id" => foreign.id})

      assert %{public_intake_stage_id: ["must be a stage on this board"]} = errors_on(changeset)
    end
  end

  describe "get_public_board/1" do
    test "returns the board only when public_enabled" do
      board = insert(:board, public_enabled: true)
      assert {:ok, found} = Boards.get_public_board(board.slug)
      assert found.id == board.id
    end

    test "is :error when disabled or unknown" do
      disabled = insert(:board, public_enabled: false)
      assert :error = Boards.get_public_board(disabled.slug)
      assert :error = Boards.get_public_board("no-such-slug")
    end
  end

  describe "list_public_cards/1" do
    test "includes public-category cards, excludes done and archived, using Stage.public_categories/0" do
      board = insert(:board)
      unstarted = insert(:stage, board: board, category: :unstarted)
      done = insert(:stage, board: board, category: :complete, type: :done)

      shown = insert(:card, stage: unstarted)
      _done_card = insert(:card, stage: done)
      _archived = insert(:card, stage: unstarted, archived_at: ~U[2026-01-01 00:00:00Z])

      assert Enum.map(Boards.list_public_cards(board), & &1.id) == [shown.id]
      # magic-value guard: the query filters on exactly the shared source list
      assert Stage.public_categories() == [:unstarted, :planning, :in_progress]
    end

    test "drops hidden cards and cards by a suspended poster, until the suspension lifts" do
      board = insert(:board, public_enabled: true)
      unstarted = insert(:stage, board: board, category: :unstarted)
      suspended = insert(:user, suspended_at: ~U[2026-01-01 00:00:00Z])

      _hidden = insert(:card, stage: unstarted, hidden_at: ~U[2026-01-01 00:00:00Z], hidden_reason: :admin)
      by_suspended = insert(:card, stage: unstarted, posted_by_user_id: suspended.id)
      normal = insert(:card, stage: unstarted)

      assert Enum.map(Boards.list_public_cards(board), & &1.id) == [normal.id]

      suspended |> Ecto.Changeset.change(suspended_at: nil) |> Repo.update!()

      assert board |> Boards.list_public_cards() |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([normal.id, by_suspended.id])
    end
  end
end
