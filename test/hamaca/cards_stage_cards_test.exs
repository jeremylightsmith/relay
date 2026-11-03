defmodule Hamaca.CardsStageCardsTest do
  use Hamaca.DataCase, async: true

  alias Hamaca.Cards
  alias Schemas.Card
  alias Schemas.CardOwner

  setup do
    board = insert(:board, key: "RLY")
    stage = insert(:stage, board: board, position: 1)
    other = insert(:stage, board: board, position: 2)
    %{board: board, stage: stage, other: other}
  end

  describe "list_stage_cards/2" do
    test "returns at most `limit` cards", %{stage: stage} do
      for i <- 1..10 do
        insert(:card,
          stage: stage,
          updated_at: DateTime.add(~U[2026-07-01 00:00:00Z], i, :second)
        )
      end

      assert length(Cards.list_stage_cards(stage, 8)) == 8
    end

    test "orders newest-first by effective done time: done_at wins over updated_at", %{stage: stage} do
      a = insert(:card, stage: stage, done_at: ~U[2026-10-01 12:00:00Z], updated_at: ~U[2026-10-20 00:00:00Z])
      b = insert(:card, stage: stage, done_at: ~U[2026-10-02 12:00:00Z], updated_at: ~U[2026-10-02 12:00:00Z])

      assert ids(Cards.list_stage_cards(stage, 8)) == [b.id, a.id]
    end

    test "ties on done_at order by id desc", %{stage: stage} do
      # updated_at runs against id, so only the id tiebreak yields [second, first].
      first = insert(:card, stage: stage, done_at: ~U[2026-10-01 12:00:00Z], updated_at: ~U[2026-10-30 12:00:00Z])
      second = insert(:card, stage: stage, done_at: ~U[2026-10-01 12:00:00Z], updated_at: ~U[2026-10-01 12:00:00Z])

      assert ids(Cards.list_stage_cards(stage, 8)) == [second.id, first.id]
    end

    test "is scoped to the one stage", %{stage: stage, other: other} do
      mine = insert(:card, stage: stage)
      _theirs = insert(:card, stage: other)

      assert [%Card{id: id}] = Cards.list_stage_cards(stage, 8)
      assert id == mine.id
    end

    test "excludes archived cards", %{stage: stage} do
      _archived = insert(:card, stage: stage, archived_at: ~U[2026-07-01 00:00:00Z])
      live = insert(:card, stage: stage)

      assert [%Card{id: id}] = Cards.list_stage_cards(stage, 8)
      assert id == live.id
    end

    test "preloads owners and sub_tasks", %{stage: stage} do
      card = insert(:card, stage: stage)
      insert(:card_owner, card: card)

      assert [loaded] = Cards.list_stage_cards(stage, 8)
      assert [%CardOwner{}] = loaded.owners
      assert is_list(loaded.sub_tasks)
    end
  end

  describe "list_done_cards/2" do
    test "returns every non-archived card done at or after the cutoff, newest first, preloaded", %{stage: stage} do
      newest = done(stage, ~U[2026-11-04 10:00:00Z])
      at_cutoff = done(stage, ~U[2026-11-02 00:00:00Z])
      _before = done(stage, ~U[2026-11-01 23:59:59Z])
      _archived = done(stage, ~U[2026-11-05 10:00:00Z], archived_at: ~U[2026-11-05 11:00:00Z])
      insert(:card_owner, card: newest)

      cards = Cards.list_done_cards(stage, ~U[2026-11-02 00:00:00Z])

      assert ids(cards) == [newest.id, at_cutoff.id]
      assert [[%CardOwner{}], []] = Enum.map(cards, & &1.owners)
      assert Enum.all?(cards, &is_list(&1.sub_tasks))
    end

    test "falls back to updated_at when done_at is nil", %{stage: stage} do
      legacy = insert(:card, stage: stage, done_at: nil, updated_at: ~U[2026-10-14 00:00:00Z])

      assert ids(Cards.list_done_cards(stage, ~U[2026-10-12 00:00:00Z])) == [legacy.id]
    end

    test "is scoped to the one stage", %{stage: stage, other: other} do
      mine = done(stage, ~U[2026-11-04 10:00:00Z])
      _theirs = done(other, ~U[2026-11-04 10:00:00Z])

      assert ids(Cards.list_done_cards(stage, ~U[2026-11-02 00:00:00Z])) == [mine.id]
    end
  end

  describe "latest_done_cutoff/2 and older_done_cutoff/4" do
    setup %{stage: stage} do
      # One card in each of the UTC weeks starting Nov 2, Oct 26, Oct 12, Sep 28, Sep 14, Aug 3.
      for at <- [
            ~U[2026-11-03 10:00:00Z],
            ~U[2026-10-28 10:00:00Z],
            ~U[2026-10-14 10:00:00Z],
            ~U[2026-09-30 10:00:00Z],
            ~U[2026-09-16 10:00:00Z],
            ~U[2026-08-05 10:00:00Z]
          ] do
        done(stage, at)
      end

      :ok
    end

    test "the latest cutoff is the Monday of the newest done week", %{stage: stage} do
      assert Cards.latest_done_cutoff(stage, "Etc/UTC") == ~U[2026-11-02 00:00:00Z]
    end

    test "the older cutoff spans the next 4 non-empty weeks", %{stage: stage} do
      assert Cards.older_done_cutoff(stage, ~U[2026-11-02 00:00:00Z], "Etc/UTC", 4) == ~U[2026-09-14 00:00:00Z]
    end

    test "the older cutoff is the oldest week when fewer than n remain", %{stage: stage} do
      assert Cards.older_done_cutoff(stage, ~U[2026-09-14 00:00:00Z], "Etc/UTC", 4) == ~U[2026-08-03 00:00:00Z]
    end

    test "the older cutoff is nil when nothing older remains", %{stage: stage} do
      assert Cards.older_done_cutoff(stage, ~U[2026-08-03 00:00:00Z], "Etc/UTC", 4) == nil
    end
  end

  describe "latest_done_cutoff/2" do
    test "buckets in the viewer's zone", %{stage: stage} do
      done(stage, ~U[2026-11-02 03:00:00Z])

      # Still Sunday Nov 1 in Los Angeles.
      assert Cards.latest_done_cutoff(stage, "America/Los_Angeles") == ~U[2026-10-26 07:00:00Z]
      assert Cards.latest_done_cutoff(stage, "Etc/UTC") == ~U[2026-11-02 00:00:00Z]
    end

    test "is nil for an empty stage", %{stage: stage} do
      assert Cards.latest_done_cutoff(stage, "Etc/UTC") == nil
    end

    test "is nil for a stage holding only archived cards", %{stage: stage} do
      done(stage, ~U[2026-11-02 03:00:00Z], archived_at: ~U[2026-11-03 00:00:00Z])

      assert Cards.latest_done_cutoff(stage, "Etc/UTC") == nil
    end
  end

  describe "done_before?/2" do
    test "is true when a card was done before the cutoff", %{stage: stage} do
      done(stage, ~U[2026-11-01 23:00:00Z])

      assert Cards.done_before?(stage, ~U[2026-11-02 00:00:00Z])
    end

    test "is false when every card was done at or after the cutoff", %{stage: stage} do
      done(stage, ~U[2026-11-02 00:00:00Z])
      done(stage, ~U[2026-11-03 00:00:00Z])

      refute Cards.done_before?(stage, ~U[2026-11-02 00:00:00Z])
    end

    test "ignores archived older cards", %{stage: stage} do
      done(stage, ~U[2026-11-01 23:00:00Z], archived_at: ~U[2026-11-03 00:00:00Z])

      refute Cards.done_before?(stage, ~U[2026-11-02 00:00:00Z])
    end
  end

  describe "done_weeks_per_page/0" do
    test "is a positive batch size of 4 weeks" do
      assert Cards.done_weeks_per_page() == 4
    end
  end

  defp done(stage, at, attrs \\ []) do
    insert(:card, Keyword.merge([stage: stage, done_at: at, updated_at: at], attrs))
  end

  defp ids(cards), do: Enum.map(cards, & &1.id)
end
