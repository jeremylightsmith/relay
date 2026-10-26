defmodule Relay.Usage.TrackerTest do
  @moduledoc """
  RE475 — `Relay.Usage.Tracker` keeps one open visit per user in memory (a run of touches with no
  gap longer than `Relay.Usage.idle_gap/0`) and upserts the dirty ones into `usage_visits` on
  `flush/1`, keyed by `(user_id, started_at)`.
  """
  use Relay.DataCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Relay.Usage
  alias Relay.Usage.Tracker

  @t0 ~U[2026-10-20 10:00:00Z]

  setup do
    name = :"usage_tracker_#{System.unique_integer([:positive])}"
    tracker = allow!(start_supervised!({Tracker, name: name, flush_ms: 3_600_000}))

    {:ok, tracker: tracker, name: name, user: insert(:user)}
  end

  defp at(minutes), do: DateTime.add(@t0, minutes * 60)

  defp touch(tracker, user, attrs, minutes), do: Tracker.touch(user, attrs, server: tracker, at: at(minutes))

  defp rows(user) do
    Repo.all(from v in Schemas.UsageVisit, where: v.user_id == ^user.id, order_by: v.started_at)
  end

  describe "touch/3 and open_visits/1" do
    test "touches inside the idle gap extend one open visit", %{tracker: tracker, user: user} do
      board = insert(:board)

      for minutes <- [0, 10, 29] do
        assert :ok = touch(tracker, user, %{board_id: board.id, card_ref: "RL7"}, minutes)
      end

      user_id = user.id
      assert [{^user_id, visit}] = Map.to_list(Tracker.open_visits(tracker))

      assert %{started_at: @t0, card_refs: ["RL7"], dirty?: true, board_id: board_id} = visit
      assert visit.last_at == at(29)
      assert board_id == board.id
    end

    test "a dev or seed user is never tracked, and a nil user is a no-op", %{tracker: tracker} do
      for provider <- Schemas.User.synthetic_providers() do
        assert :ok = touch(tracker, insert(:user, provider: provider), %{}, 0)
      end

      assert :ok = Tracker.touch(nil, %{}, server: tracker)

      assert Tracker.open_visits(tracker) == %{}
      assert Tracker.flush(tracker) == {:ok, 0}
    end

    test "card_refs keeps the 10 most recently touched refs, without duplicates", %{tracker: tracker, user: user} do
      for n <- 1..12, do: touch(tracker, user, %{card_ref: "RL#{n}"}, n)
      touch(tracker, user, %{card_ref: "RL3"}, 13)

      expected = Enum.map(4..12, &"RL#{&1}") ++ ["RL3"]
      assert %{card_refs: ^expected} = Tracker.open_visits(tracker)[user.id]
      assert length(expected) == Usage.max_card_refs()

      touch(tracker, user, %{card_ref: String.duplicate("x", 40)}, 14)

      visit = Tracker.open_visits(tracker)[user.id]
      assert visit.card_refs == expected
      assert visit.last_at == at(14)
    end

    test "a nil board never overwrites the visit's board; a new board does", %{tracker: tracker, user: user} do
      b1 = insert(:board)
      b2 = insert(:board)

      touch(tracker, user, %{board_id: b1.id}, 0)
      touch(tracker, user, %{board_id: nil}, 1)
      assert Tracker.open_visits(tracker)[user.id].board_id == b1.id

      touch(tracker, user, %{board_id: b2.id}, 2)
      assert Tracker.open_visits(tracker)[user.id].board_id == b2.id
    end
  end

  describe "flush/1" do
    test "a touch past the idle gap opens a second visit, and both are written", %{tracker: tracker, user: user} do
      touch(tracker, user, %{}, 0)
      touch(tracker, user, %{}, 31)

      assert Tracker.flush(tracker) == {:ok, 2}
      assert [first, second] = rows(user)
      assert first.started_at == @t0
      assert second.started_at == at(31)
    end

    test "the upsert updates the same row in place", %{tracker: tracker, user: user} do
      touch(tracker, user, %{}, 0)
      touch(tracker, user, %{}, 5)
      assert {:ok, 1} = Tracker.flush(tracker)

      assert [%{seconds: 300} = row] = rows(user)
      assert row.last_at == at(5)

      touch(tracker, user, %{}, 12)
      assert {:ok, 1} = Tracker.flush(tracker)

      assert [updated] = rows(user)
      assert updated.id == row.id
      assert updated.started_at == row.started_at
      assert updated.seconds == 720
    end

    test "a single touch is floored at min_visit_seconds", %{tracker: tracker, user: user} do
      touch(tracker, user, %{}, 0)
      assert {:ok, 1} = Tracker.flush(tracker)

      assert [%{seconds: 60}] = rows(user)
    end

    test "with nothing dirty it returns {:ok, 0} and issues no query", %{tracker: tracker, user: user} do
      touch(tracker, user, %{}, 0)
      assert {:ok, 1} = Tracker.flush(tracker)

      test_pid = self()
      handler = "usage-tracker-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:relay, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == tracker, do: send(test_pid, :tracker_query)
        end,
        nil
      )

      try do
        assert Tracker.flush(tracker) == {:ok, 0}
      after
        :telemetry.detach(handler)
      end

      refute_received :tracker_query
    end

    test "a graceful shutdown flushes dirty visits" do
      user = insert(:user)
      name = :"usage_tracker_#{System.unique_integer([:positive])}"
      tracker = allow!(start_supervised!({Tracker, name: name, flush_ms: 3_600_000}, id: :shutdown_tracker))

      touch(tracker, user, %{}, 0)
      :ok = stop_supervised!(:shutdown_tracker)

      assert [%{started_at: @t0}] = rows(user)
    end

    test "a DB error drops the batch, logs one warning, and keeps the tracker alive", %{
      tracker: tracker,
      name: name,
      user: user
    } do
      touch(tracker, user, %{}, 0)
      _ = :sys.get_state(tracker)
      Repo.delete!(user)

      {result, log} = with_log([level: :warning], fn -> Tracker.flush(tracker) end)

      assert result == {:ok, 0}
      assert log =~ ~r/\[warning\] Usage tracker dropped/
      assert [_one_line] = log |> String.split("\n", trim: true) |> Enum.filter(&(&1 =~ "Usage tracker dropped"))
      assert GenServer.whereis(name) == tracker

      other = insert(:user)
      touch(tracker, other, %{}, 1)
      assert Tracker.flush(tracker) == {:ok, 1}
      assert [_row] = rows(other)
    end

    test "a written visit idle past the gap leaves memory on the next flush", %{tracker: tracker, user: user} do
      touch(tracker, user, %{}, 0)
      assert {:ok, 1} = Tracker.flush(tracker)
      assert Map.has_key?(Tracker.open_visits(tracker), user.id)

      assert {:ok, 0} = Tracker.flush(tracker)
      refute Map.has_key?(Tracker.open_visits(tracker), user.id)
    end
  end

  describe "Relay.Usage definitions" do
    test "visit_seconds floors at min_visit_seconds, and the policy numbers" do
      assert Usage.visit_seconds(@t0, @t0) == 60
      assert Usage.visit_seconds(@t0, DateTime.add(@t0, 125)) == 125
      assert Usage.idle_gap() == 1800
      assert Usage.min_visit_seconds() == 60
    end
  end
end
