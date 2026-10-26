defmodule Relay.UsageTest do
  @moduledoc """
  RE475 — the `Relay.Usage` read model: `overview/2` (tiles + chart), `user_rows/1` (the table)
  and `user_detail/2` (the panel). Superadmins are listed but uncounted; synthetic (dev/seed)
  users are absent everywhere. Runs and shipped cards belong to the owner of the card's board.
  """
  use Relay.DataCase, async: true

  alias Relay.Usage
  alias Schemas.Scope
  alias Schemas.UsageVisit

  @now ~U[2026-10-25 15:00:00Z]
  @today ~D[2026-10-25]

  defp noon(date), do: DateTime.new!(date, ~T[12:00:00], "Etc/UTC")

  # A "visit on D" starts at 12:00 on D.
  defp visit(user, date, attrs \\ []) do
    started_at = noon(date)
    seconds = Keyword.get(attrs, :seconds, 60)

    Repo.insert!(%UsageVisit{
      user_id: user.id,
      started_at: Keyword.get(attrs, :started_at, started_at),
      last_at: Keyword.get(attrs, :last_at, DateTime.add(started_at, seconds)),
      seconds: seconds,
      board_id: Keyword.get(attrs, :board_id),
      card_refs: Keyword.get(attrs, :card_refs, [])
    })
  end

  defp run_on(board, date) do
    card = insert(:card, stage: insert(:stage, board: board))
    insert(:run, card: card, status: :done, started_at: noon(date))
  end

  defp superadmin, do: insert(:user, email: hd(Scope.superadmin_emails()))

  defp row(rows, user), do: Enum.find(rows, &(&1.id == user.id))

  describe "vocabularies and windows" do
    test "ranges, default range, day states and the fixed windows (scenario 17)" do
      assert Usage.ranges() == [7, 30, 90]
      assert Usage.default_range() == 30
      assert Usage.day_states() == [:none, :human, :agent, :both]
      assert Usage.strip_days() == 14
      assert Usage.window_days() == 7
    end

    test "window_start/2 is midnight UTC of the window's first date (scenario 17)" do
      assert Usage.window_start(7, @now) == ~U[2026-10-19 00:00:00Z]
      assert Usage.window_start(1, @now) == ~U[2026-10-25 00:00:00Z]
    end
  end

  describe "overview/2" do
    test "counts active counted users today and this week, excluding superadmins (scenario 1)" do
      a = insert(:user)
      b = insert(:user)
      _c = insert(:user)
      s = superadmin()
      visit(a, @today)
      visit(a, ~D[2026-10-20])
      visit(b, ~D[2026-10-19])
      visit(s, @today)

      overview = Usage.overview(30, @now)

      assert overview.active_today == 1
      assert overview.this_week == 2
      assert overview.counted_users == 3
    end

    test "active_last_week is the active count on the same weekday a week ago (scenario 2)" do
      a = insert(:user)
      b = insert(:user)
      visit(a, ~D[2026-10-18])
      visit(a, @today)
      visit(b, @today)

      overview = Usage.overview(30, @now)

      assert overview.active_last_week == 1
      assert overview.active_today == 2
    end

    test "median visit length over the 7d window counts counted users only (scenario 3)" do
      a = insert(:user)
      s = superadmin()
      visit(a, ~D[2026-10-20], seconds: 120)
      visit(a, ~D[2026-10-21], seconds: 420)
      visit(a, ~D[2026-10-22], seconds: 600)
      visit(s, ~D[2026-10-22], seconds: 3000)

      assert Usage.overview(30, @now).median_visit_seconds_7d == 420
    end

    test "median and visits per active day are nil with no counted visits (scenario 3)" do
      s = superadmin()
      visit(s, @today, seconds: 3000)

      overview = Usage.overview(30, @now)

      assert overview.median_visit_seconds_7d == nil
      assert overview.visits_per_active_day_7d == nil
    end

    test "visits per active day divides visits by user-days (scenario 4)" do
      a = insert(:user)
      b = insert(:user)
      visit(a, ~D[2026-10-24], started_at: ~U[2026-10-24 08:00:00Z])
      visit(a, ~D[2026-10-24], started_at: ~U[2026-10-24 12:00:00Z])
      visit(a, ~D[2026-10-24], started_at: ~U[2026-10-24 18:00:00Z])
      visit(b, @today)

      assert Usage.overview(30, @now).visits_per_active_day_7d == 2.0
    end

    test "agent runs in the 7d window belong to counted board owners (scenario 5)" do
      a = insert(:user)
      b = insert(:user)
      s = superadmin()
      ba = insert(:board, owner: a)
      bb = insert(:board, owner: b)
      bs = insert(:board, owner: s)
      for date <- [~D[2026-10-19], ~D[2026-10-22], @today], do: run_on(ba, date)
      run_on(bb, ~D[2026-10-15])
      for _ <- 1..5, do: run_on(bs, @today)

      overview = Usage.overview(30, @now)

      assert overview.agent_runs_7d == 3
      assert overview.agent_run_owners_7d == 1
    end

    test "series stacks people and agents whose owner did not visit (scenario 6)" do
      a = insert(:user)
      b = insert(:user)
      c = insert(:user)
      visit(a, ~D[2026-10-24])
      run_on(insert(:board, owner: a), ~D[2026-10-24])
      run_on(insert(:board, owner: b), ~D[2026-10-24])
      visit(c, ~D[2026-10-24])

      series = Usage.overview(7, @now).series

      assert length(series) == 7
      assert hd(series).date == ~D[2026-10-19]
      assert List.last(series).date == ~D[2026-10-25]
      assert Enum.find(series, &(&1.date == ~D[2026-10-24])) == %{date: ~D[2026-10-24], people: 2, agents: 1}
    end

    test "a 90-day series with no data is 90 zero entries ending today (scenario 7)" do
      series = Usage.overview(90, @now).series

      assert length(series) == 90
      assert hd(series).date == ~D[2026-07-28]
      assert List.last(series).date == @today
      assert Enum.all?(series, &(&1.people == 0 and &1.agents == 0))
    end
  end

  describe "synthetic users (scenario 8)" do
    setup do
      dev = insert(:user, provider: "dev")
      seed = insert(:user, provider: "seed")

      for user <- [dev, seed] do
        visit(user, @today)
        run_on(insert(:board, owner: user), @today)
      end

      %{dev: dev, seed: seed}
    end

    test "appear in no overview field" do
      overview = Usage.overview(7, @now)

      assert overview.active_today == 0
      assert overview.this_week == 0
      assert overview.counted_users == 0
      assert overview.agent_runs_7d == 0
      assert overview.agent_run_owners_7d == 0
      assert overview.median_visit_seconds_7d == nil
      assert Enum.all?(overview.series, &(&1.people == 0 and &1.agents == 0))
    end

    test "have no user row and no detail, while a real user is listed", %{dev: dev, seed: seed} do
      real = insert(:user, provider: "google")

      assert Enum.map(Usage.user_rows(@now), & &1.id) == [real.id]
      assert Usage.user_detail(dev.id, @now) == nil
      assert Usage.user_detail(seed.id, @now) == nil
      assert %{id: id} = Usage.user_detail(real.id, @now)
      assert id == real.id
    end
  end

  describe "user_rows/1" do
    test "lists superadmins uncounted with their visits and strip (scenario 9)" do
      s = superadmin()
      a = insert(:user)
      visit(s, @today, seconds: 300)

      rows = Usage.user_rows(@now)
      s_row = row(rows, s)

      assert s_row.counted? == false
      assert s_row.visits_7d == 1
      assert s_row.seconds_7d == 300
      assert List.last(s_row.strip) == :human
      assert row(rows, a).counted? == true
      assert Enum.all?(rows -- [s_row], & &1.counted?)
    end

    test "orders by last seen, never-seen last, with the last visit's board and card (scenario 10)" do
      a = insert(:user)
      b = insert(:user)
      c = insert(:user)
      board = insert(:board, owner: a, name: "Relay")

      visit(a, @today,
        started_at: ~U[2026-10-25 11:00:00Z],
        last_at: ~U[2026-10-25 12:00:00Z],
        seconds: 3600,
        board_id: board.id,
        card_refs: ["RE1", "RE475"]
      )

      visit(a, ~D[2026-10-20], board_id: nil, card_refs: ["RE9"])
      visit(b, ~D[2026-10-23])

      rows = Usage.user_rows(@now)

      assert Enum.map(rows, & &1.id) == [a.id, b.id, c.id]

      assert %{last_board_name: "Relay", last_card_ref: "RE475", last_seen_at: ~U[2026-10-25 12:00:00Z]} =
               row(rows, a)

      assert %{last_seen_at: nil, last_board_name: nil, last_card_ref: nil, visits_7d: 0, seconds_7d: 0} =
               row(rows, c)
    end

    test "ties on last seen fall back to id ascending (scenario 10)" do
      users = for _ <- 1..3, do: insert(:user)

      assert Enum.map(Usage.user_rows(@now), & &1.id) == Enum.sort(Enum.map(users, & &1.id))
    end

    test "a last visit with no board has no board name (scenario 10)" do
      a = insert(:user)
      visit(a, @today, board_id: nil, card_refs: [])

      assert %{last_board_name: nil, last_card_ref: nil} = row(Usage.user_rows(@now), a)
    end

    test "strip is 14 days of human/agent/both, oldest first (scenario 11)" do
      a = insert(:user)
      board = insert(:board, owner: a)
      visit(a, ~D[2026-10-11])
      run_on(board, ~D[2026-10-11])
      visit(a, ~D[2026-10-12])
      visit(a, @today)
      run_on(board, ~D[2026-10-24])
      run_on(board, @today)

      strip = row(Usage.user_rows(@now), a).strip

      assert length(strip) == 14
      assert Enum.at(strip, 0) == :human
      assert Enum.at(strip, 12) == :agent
      assert Enum.at(strip, 13) == :both
      assert strip |> Enum.slice(1..11) |> Enum.all?(&(&1 == :none))
    end

    test "visits and seconds sum the 7d window (scenario 12)" do
      a = insert(:user)
      visit(a, ~D[2026-10-20], seconds: 300)
      visit(a, @today, seconds: 900)
      visit(a, ~D[2026-10-17], seconds: 5000)

      assert %{visits_7d: 2, seconds_7d: 1200} = row(Usage.user_rows(@now), a)
    end

    test "runs go to the board owner, never a member, and never on an archived board (scenario 14)" do
      a = insert(:user)
      b = insert(:user)
      ba = insert(:board, owner: a)
      insert(:membership, board: ba, user: b)
      run_on(ba, ~D[2026-10-23])
      run_on(ba, @today)
      archived = insert(:board, owner: a, archived_at: ~U[2026-10-01 00:00:00Z])
      run_on(archived, @today)

      rows = Usage.user_rows(@now)

      assert row(rows, b).runs_7d == 0
      assert row(rows, a).runs_7d == 2
    end

    test "issues the same number of queries for 5 users as for 1 (scenario 18)" do
      seed_active_user = fn ->
        user = insert(:user)
        board = insert(:board, owner: user)
        visit(user, @today, board_id: board.id, card_refs: ["RL1"])
        run_on(board, @today)
      end

      seed_active_user.()
      {[_], one} = count_repo_queries(self(), fn -> Usage.user_rows(@now) end)

      for _ <- 1..4, do: seed_active_user.()
      {rows, five} = count_repo_queries(self(), fn -> Usage.user_rows(@now) end)

      assert length(rows) == 5
      assert five == one
    end
  end

  describe "shipped (scenario 13)" do
    setup do
      a = insert(:user)
      ba = insert(:board, owner: a)
      done = insert(:stage, board: ba, category: :complete, parent_id: nil)
      code = insert(:stage, board: ba, category: :in_progress)
      done_sub = insert(:stage, board: ba, category: :complete, parent_id: done.id)

      move = fn card, type, from, to, date ->
        insert(:activity,
          card: card,
          type: type,
          meta: %{"from_stage_id" => from.id, "to_stage_id" => to.id},
          inserted_at: noon(date)
        )
      end

      x = insert(:card, stage: done)
      move.(x, :moved, code, done, ~D[2026-10-20])

      y = insert(:card, stage: done)
      move.(y, :approved, code, done, ~D[2026-10-21])
      move.(y, :moved, done, code, ~D[2026-10-22])
      move.(y, :moved, code, done, ~D[2026-10-23])

      z = insert(:card, stage: done)
      move.(z, :approved, done, done, @today)

      sub = insert(:card, stage: done_sub)
      move.(sub, :moved, code, done_sub, @today)

      old = insert(:card, stage: done)
      move.(old, :moved, code, done, ~D[2026-10-17])

      %{a: a}
    end

    test "counts distinct cards that entered top-level Done in the window, in user_rows", %{a: a} do
      assert row(Usage.user_rows(@now), a).shipped_7d == 2
    end

    test "counts the same in user_detail", %{a: a} do
      assert Usage.user_detail(a.id, @now).shipped_7d == 2
    end
  end

  describe "user_detail/2" do
    test "waiting counts unarchived cards awaiting a human (scenario 15)" do
      a = insert(:user)
      stage = insert(:stage, board: insert(:board, owner: a))
      insert(:card, stage: stage, status: :needs_input)
      insert(:card, stage: stage, status: :in_review)
      insert(:card, stage: stage, status: :working)
      insert(:card, stage: stage, status: :needs_input, archived_at: ~U[2026-10-20 00:00:00Z])

      assert Usage.user_detail(a.id, @now).waiting == 2
    end

    test "recent visits, active days, board count and identity (scenario 16)" do
      a = insert(:user, inserted_at: ~U[2026-09-01 10:00:00Z])
      board = insert(:board, owner: a, name: "Relay")
      insert(:board, owner: a)
      insert(:board, owner: a, archived_at: ~U[2026-10-01 00:00:00Z])

      # 12 visits: two each on 10-20..10-25 (6 distinct days).
      for offset <- 0..5, hour <- [9, 14] do
        date = Date.add(@today, -offset)

        visit(a, date,
          started_at: DateTime.new!(date, Time.new!(hour, 0, 0), "Etc/UTC"),
          seconds: 60 * (offset + 1),
          board_id: if(hour == 9, do: nil, else: board.id),
          card_refs: ["RL#{offset}"]
        )
      end

      detail = Usage.user_detail(a.id, @now)

      assert length(detail.recent_visits) == 10
      started = Enum.map(detail.recent_visits, & &1.started_at)
      assert started == Enum.sort(started, {:desc, DateTime})
      assert hd(detail.recent_visits).started_at == ~U[2026-10-25 14:00:00Z]

      assert %{board_name: "Relay", card_refs: ["RL0"], seconds: 60} = hd(detail.recent_visits)
      assert %{board_name: nil, card_refs: ["RL0"], seconds: 60} = Enum.at(detail.recent_visits, 1)
      assert Enum.all?(detail.recent_visits, &is_integer(&1.id))

      assert detail.active_days_14 == 6
      assert detail.board_count == 2
      assert detail.inserted_at == ~U[2026-09-01 10:00:00Z]
      assert detail.id == a.id
      assert detail.email == a.email
      assert detail.name == a.name
      assert detail.counted? == true
      assert length(detail.strip) == 14
      assert detail.visits_7d == 12
    end

    test "is nil for an unknown id (scenario 17)" do
      assert Usage.user_detail(-1, @now) == nil
    end
  end
end
