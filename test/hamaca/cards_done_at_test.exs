defmodule Hamaca.CardsDoneAtTest do
  @moduledoc """
  RE504 — `cards.done_at` is stamped when a card enters its board's terminal stage, kept while
  it stays there, and cleared when it leaves. A mid-board `:done` sub-lane is not terminal.
  """
  use Hamaca.DataCase, async: true

  import Ecto.Query

  alias Hamaca.Boards
  alias Hamaca.Cards
  alias Schemas.Card

  @stamp ~U[2026-10-01 00:00:00Z]

  setup do
    board = Boards.get_or_create_default_board(insert(:user))
    code = stage_named(board, "Code")
    {:ok, code_review} = Boards.enable_lane(code, :review)
    {:ok, code_done} = Boards.enable_lane(code, :done)

    %{
      board: board,
      backlog: stage_named(board, "Backlog"),
      code: code,
      code_review: code_review,
      code_done: code_done,
      terminal: stage_named(board, "Done")
    }
  end

  defp stage_named(board, name), do: Enum.find(board.stages, &(&1.name == name))

  defp reload(%Card{id: id}), do: Repo.get!(Card, id)

  defp set_done_at!(%Card{id: id}, done_at) do
    {1, _} = Repo.update_all(from(c in Card, where: c.id == ^id), set: [done_at: done_at])
    Repo.get!(Card, id)
  end

  defp assert_recent(%DateTime{} = at) do
    assert abs(DateTime.diff(DateTime.utc_now(), at, :second)) <= 5
  end

  describe "moving into the terminal stage" do
    test "a card from a work stage gets done_at stamped now", %{code: code, terminal: terminal} do
      card = insert(:card, stage: code)

      assert {:ok, _} = Cards.move_card(card, terminal, 0, :agent)

      assert %DateTime{} = done_at = reload(card).done_at
      assert_recent(done_at)
    end

    test "a card from a :review sub-lane gets done_at", %{code_review: code_review, terminal: terminal} do
      card = insert(:card, stage: code_review)

      assert {:ok, _} = Cards.move_card(card, terminal, 0, :agent)

      assert %DateTime{} = reload(card).done_at
    end

    test "a card from a mid-board :done sub-lane gets done_at", %{code_done: code_done, terminal: terminal} do
      card = insert(:card, stage: code_done)

      assert {:ok, _} = Cards.move_card(card, terminal, 0, :agent)

      assert %DateTime{} = reload(card).done_at
    end
  end

  test "moving into a mid-board :done sub-lane leaves done_at nil", %{code: code, code_done: code_done} do
    card = insert(:card, stage: code)

    assert {:ok, _} = Cards.move_card(card, code_done, 0, :agent)

    assert reload(card).done_at == nil
  end

  describe "creating a card" do
    test "born in the terminal stage it gets done_at", %{terminal: terminal} do
      assert {:ok, card} = Cards.create_card(terminal, %{title: "born done"})

      assert %DateTime{} = reload(card).done_at
    end

    test "born in a non-terminal stage it has no done_at", %{backlog: backlog} do
      assert {:ok, card} = Cards.create_card(backlog, %{title: "x"})

      assert reload(card).done_at == nil
    end
  end

  describe "a card staying in the terminal stage keeps its done_at" do
    setup %{terminal: terminal} do
      for _ <- 1..3, do: insert(:card, stage: terminal, done_at: @stamp)
      %{card: terminal |> then(&insert(:card, stage: &1)) |> set_done_at!(@stamp)}
    end

    test "when reordered within Done", %{card: card, terminal: terminal} do
      assert {:ok, _} = Cards.move_card(card, terminal, 2)

      assert reload(card).done_at == @stamp
    end

    test "when its title is edited", %{card: card} do
      assert {:ok, _} = Cards.update_card(card, %{title: "edited"})

      assert reload(card).done_at == @stamp
    end

    test "when its status changes", %{card: card} do
      assert {:ok, _} = Cards.set_status(card, %{status: :working}, :agent)

      assert reload(card).done_at == @stamp
    end
  end

  test "leaving the terminal stage clears done_at; re-entering stamps a later one",
       %{code: code, terminal: terminal} do
    card = terminal |> then(&insert(:card, stage: &1)) |> set_done_at!(@stamp)

    assert {:ok, _} = Cards.move_card(card, code, 0)
    assert reload(card).done_at == nil

    assert {:ok, _} = Cards.move_card(reload(card), terminal, 0)
    assert %DateTime{} = done_at = reload(card).done_at
    assert DateTime.after?(done_at, @stamp)
  end

  describe "rehoming archived cards when a stage is deleted" do
    test "an archived card rehomed from the deleted terminal stage into the new terminal keeps done_at",
         %{board: board, terminal: terminal} do
      card =
        terminal
        |> then(&insert(:card, stage: &1, archived_at: ~U[2026-10-02 00:00:00Z]))
        |> set_done_at!(@stamp)

      assert {:ok, _} = Boards.delete_stage(terminal, :agent)

      rehomed = reload(card)
      assert rehomed.stage_id == stage_named(board, "Deploy").id
      assert rehomed.done_at == @stamp
    end

    test "an unstamped archived card rehomed from the deleted terminal stage into the new terminal is stamped",
         %{terminal: terminal} do
      card = insert(:card, stage: terminal, archived_at: ~U[2026-10-02 00:00:00Z])

      assert {:ok, _} = Boards.delete_stage(terminal, :agent)

      assert %DateTime{} = reload(card).done_at
    end

    test "an archived card rehomed into a non-terminal stage stays without done_at",
         %{board: board, code: code} do
      card = insert(:card, stage: code, archived_at: ~U[2026-10-02 00:00:00Z])

      assert {:ok, _} = Boards.delete_stage(code, :agent)

      rehomed = reload(card)
      assert rehomed.stage_id == stage_named(board, "Plan").id
      assert rehomed.done_at == nil
    end
  end

  test "list_cards/1 loads done_at", %{board: board, code: code, terminal: terminal} do
    card = insert(:card, stage: code)
    {:ok, _} = Cards.move_card(card, terminal, 0)
    stamped = reload(card).done_at
    assert %DateTime{} = stamped

    listed = board |> Cards.list_cards() |> Enum.find(&(&1.id == card.id))

    assert listed.done_at == stamped
  end
end
