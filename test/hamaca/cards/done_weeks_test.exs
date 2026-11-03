defmodule Hamaca.Cards.DoneWeeksTest do
  use ExUnit.Case, async: true

  alias Hamaca.Cards.DoneWeeks
  alias Schemas.Card

  @la "America/Los_Angeles"
  @utc "Etc/UTC"

  describe "week_start/2" do
    test "is the ISO Monday of the instant's week in UTC" do
      assert DoneWeeks.week_start(~U[2026-11-04 12:00:00Z], @utc) == ~D[2026-11-02]
      assert DoneWeeks.week_start(~U[2026-11-02 00:00:00Z], @utc) == ~D[2026-11-02]
      assert DoneWeeks.week_start(~U[2026-11-08 23:59:59Z], @utc) == ~D[2026-11-02]
    end

    test "reads the instant in the given zone, not UTC" do
      # Sunday Nov 8 23:30 PST
      assert DoneWeeks.week_start(~U[2026-11-09 07:30:00Z], @la) == ~D[2026-11-02]
      assert DoneWeeks.week_start(~U[2026-11-09 07:30:00Z], @utc) == ~D[2026-11-09]
    end

    test "both 01:30s of the fall-back Sunday land in the same week" do
      # 01:30 PST (the repeated hour) and 01:30 PDT
      assert DoneWeeks.week_start(~U[2026-11-01 08:30:00Z], @la) == ~D[2026-10-26]
      assert DoneWeeks.week_start(~U[2026-11-01 07:30:00Z], @la) == ~D[2026-10-26]
    end

    test "the spring-forward Sunday lands in its own week" do
      assert DoneWeeks.week_start(~U[2026-03-08 10:30:00Z], @la) == ~D[2026-03-02]
    end
  end

  describe "cutoff/2" do
    test "is the UTC instant of local Monday midnight" do
      assert DoneWeeks.cutoff(~D[2026-11-02], @la) == ~U[2026-11-02 08:00:00Z]
      assert DoneWeeks.cutoff(~D[2026-10-26], @la) == ~U[2026-10-26 07:00:00Z]
      assert DoneWeeks.cutoff(~D[2026-11-02], @utc) == ~U[2026-11-02 00:00:00Z]
    end

    test "never raises and always lands on the Monday's first local instant" do
      zones = [@utc, @la, "Europe/London", "Australia/Lord_Howe", "America/Havana", "Asia/Kolkata"]
      mondays = ~D[2026-01-01] |> Date.range(~D[2026-12-31]) |> Enum.filter(&(Date.day_of_week(&1) == 1))

      assert length(mondays) == 52

      for zone <- zones, monday <- mondays do
        cutoff = DoneWeeks.cutoff(monday, zone)
        assert %DateTime{time_zone: "Etc/UTC"} = cutoff

        {:ok, local} = DateTime.shift_zone(cutoff, zone)
        assert DateTime.to_date(local) == monday, "#{zone} #{monday}: #{inspect(local)}"

        # Midnight, or (on a midnight DST gap) the first instant after it: one second
        # earlier is already the previous local day.
        {:ok, before} = cutoff |> DateTime.add(-1, :second) |> DateTime.shift_zone(zone)
        assert Date.before?(DateTime.to_date(before), monday), "#{zone} #{monday}"
      end
    end
  end

  describe "range_label/2" do
    test "within one month shows the month once" do
      assert DoneWeeks.range_label(~D[2026-10-12], ~D[2026-11-04]) == "Oct 12 – 18"
    end

    test "across months shows both months" do
      assert DoneWeeks.range_label(~D[2026-09-28], ~D[2026-11-04]) == "Sep 28 – Oct 4"
      assert DoneWeeks.range_label(~D[2026-10-26], ~D[2026-11-04]) == "Oct 26 – Nov 1"
    end

    test "a week in another year than today carries the year" do
      assert DoneWeeks.range_label(~D[2025-12-22], ~D[2026-11-04]) == "Dec 22 – 28, 2025"
    end

    test "a week spanning years shows both years whenever either differs from today's" do
      assert DoneWeeks.range_label(~D[2025-12-29], ~D[2026-11-04]) == "Dec 29, 2025 – Jan 4, 2026"
      assert DoneWeeks.range_label(~D[2025-12-29], ~D[2026-01-02]) == "Dec 29, 2025 – Jan 4, 2026"
    end
  end

  describe "label/3" do
    @now ~U[2026-11-04 12:00:00Z]

    test "the current week is \"This week\" with its range" do
      assert DoneWeeks.label(~D[2026-11-02], @now, @utc) == %{title: "This week", range: "Nov 2 – 8"}
    end

    test "the previous week is \"Last week\" with its range" do
      assert DoneWeeks.label(~D[2026-10-26], @now, @utc) == %{title: "Last week", range: "Oct 26 – Nov 1"}
    end

    test "an older week is titled by its range alone" do
      assert DoneWeeks.label(~D[2026-10-12], @now, @utc) == %{title: "Oct 12 – 18", range: nil}
    end

    test "\"This week\" is decided in the viewer's zone" do
      # Still Sunday Nov 1 in Los Angeles.
      assert DoneWeeks.label(~D[2026-10-26], ~U[2026-11-02 03:00:00Z], @la).title == "This week"
    end
  end

  describe "zone/1" do
    test "keeps a zone Tz knows" do
      assert DoneWeeks.zone(@la) == @la
    end

    test "falls back to Etc/UTC for anything else" do
      for bad <- [nil, "", "Not/AZone", 42] do
        assert DoneWeeks.zone(bad) == "Etc/UTC", inspect(bad)
      end
    end
  end

  describe "group/2" do
    test "buckets an ordered list by week, newest week first, keeping order" do
      c1 = %Card{id: 1, done_at: ~U[2026-11-04 10:00:00Z], updated_at: ~U[2026-11-04 10:00:00Z]}
      c2 = %Card{id: 2, done_at: ~U[2026-11-03 10:00:00Z], updated_at: ~U[2026-11-03 10:00:00Z]}
      c3 = %Card{id: 3, done_at: ~U[2026-10-14 10:00:00Z], updated_at: ~U[2026-11-05 10:00:00Z]}

      assert DoneWeeks.group([c1, c2, c3], @utc) == [{~D[2026-11-02], [c1, c2]}, {~D[2026-10-12], [c3]}]
    end

    test "a card without done_at buckets by updated_at" do
      card = %Card{id: 4, done_at: nil, updated_at: ~U[2026-10-14 09:00:00Z]}

      assert DoneWeeks.group([card], @utc) == [{~D[2026-10-12], [card]}]
    end
  end
end
