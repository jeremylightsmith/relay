defmodule Hamaca.Usage do
  @moduledoc """
  Who uses Hamaca and how much (RE475). This module owns every usage definition; the supervised
  `Hamaca.Usage.Tracker` is the only writer of `usage_visits`.

  A **visit** is a run of signed-in activity with no gap longer than `idle_gap/0`. Its duration is
  last touch − first touch, floored at `min_visit_seconds/0` (`visit_seconds/2`). Superadmins are
  tracked (just not counted); dev and seed accounts (`Schemas.User.synthetic_providers/0`) are not.

  Each node runs its own tracker and visits are never merged across nodes, so a user served by two
  machines inside one visit gets two rows. Prod runs one machine; this is accepted.
  """

  use Boundary, deps: [Hamaca.Boards, Hamaca.Config, Hamaca.Repo, Schemas], exports: [Tracker]

  import Ecto.Query

  alias Hamaca.Boards
  alias Hamaca.Repo
  alias Schemas.Activity
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Run
  alias Schemas.Scope
  alias Schemas.Stage
  alias Schemas.UsageVisit
  alias Schemas.User

  @idle_gap 1800
  @min_visit_seconds 60
  @flush_ms 60_000
  @max_card_refs 10
  @ranges [7, 30, 90]
  @default_range 30
  @day_states [:none, :human, :agent, :both]
  @strip_days 14
  @window_days 7
  @recent_visits 10
  @shipped_types [:moved, :approved]

  @type day_state :: :none | :human | :agent | :both
  @type range :: 7 | 30 | 90

  @type overview :: %{
          active_today: non_neg_integer(),
          active_last_week: non_neg_integer(),
          this_week: non_neg_integer(),
          counted_users: non_neg_integer(),
          agent_runs_7d: non_neg_integer(),
          agent_run_owners_7d: non_neg_integer(),
          median_visit_seconds_7d: non_neg_integer() | nil,
          visits_per_active_day_7d: float() | nil,
          series: [%{date: Date.t(), people: non_neg_integer(), agents: non_neg_integer()}]
        }

  @type user_row :: %{
          id: integer(),
          name: String.t() | nil,
          email: String.t(),
          counted?: boolean(),
          last_seen_at: DateTime.t() | nil,
          last_board_name: String.t() | nil,
          last_card_ref: String.t() | nil,
          strip: [day_state()],
          visits_7d: non_neg_integer(),
          seconds_7d: non_neg_integer(),
          runs_7d: non_neg_integer(),
          shipped_7d: non_neg_integer()
        }

  @type recent_visit :: %{
          id: integer(),
          started_at: DateTime.t(),
          seconds: non_neg_integer(),
          board_name: String.t() | nil,
          card_refs: [String.t()]
        }

  @type user_detail :: %{
          id: integer(),
          name: String.t() | nil,
          email: String.t(),
          inserted_at: DateTime.t(),
          board_count: non_neg_integer(),
          counted?: boolean(),
          active_days_14: non_neg_integer(),
          visits_7d: non_neg_integer(),
          seconds_7d: non_neg_integer(),
          runs_7d: non_neg_integer(),
          shipped_7d: non_neg_integer(),
          waiting: non_neg_integer(),
          strip: [day_state()],
          recent_visits: [recent_visit()]
        }

  @doc "The longest gap (seconds) between two touches of one visit; a longer gap starts a new visit."
  @spec idle_gap() :: pos_integer()
  def idle_gap, do: @idle_gap

  @doc "The shortest a visit can last (seconds): a single touch counts as one minute."
  @spec min_visit_seconds() :: pos_integer()
  def min_visit_seconds, do: @min_visit_seconds

  @doc "How often (ms) the tracker writes its dirty visits."
  @spec flush_ms() :: pos_integer()
  def flush_ms, do: @flush_ms

  @doc "How many of the most recently opened card refs a visit keeps."
  @spec max_card_refs() :: pos_integer()
  def max_card_refs, do: @max_card_refs

  @doc "A visit's duration in seconds: `last_at − started_at`, floored at `min_visit_seconds/0`."
  @spec visit_seconds(DateTime.t(), DateTime.t()) :: pos_integer()
  def visit_seconds(started_at, last_at), do: max(DateTime.diff(last_at, started_at), @min_visit_seconds)

  # ---------------------------------------------------------------------------------------------
  # Read model (the superadmin Usage tab). Every read is a fixed number of grouped queries — users,
  # visits by (user, date), runs by (owner, date), shipped by owner, last visit per user — merged
  # in memory, so the query count never grows with the number of users. Days are UTC dates: the
  # columns store UTC in `timestamp without time zone`, so `::date` buckets them correctly.
  # Durations are the tracker's stored `seconds`; nothing here recomputes them.
  # ---------------------------------------------------------------------------------------------

  @doc "The chart ranges (days) the Usage tab offers."
  @spec ranges() :: [range()]
  def ranges, do: @ranges

  @doc "The chart range shown when none is chosen."
  @spec default_range() :: 30
  def default_range, do: @default_range

  @doc "A day's state in a user's strip: visited (`:human`), had a run (`:agent`), both, or neither."
  @spec day_states() :: [day_state()]
  def day_states, do: @day_states

  @doc "How many days a user's activity strip covers, ending today."
  @spec strip_days() :: 14
  def strip_days, do: @strip_days

  @doc "The window (days, ending today) every `_7d` figure covers."
  @spec window_days() :: 7
  def window_days, do: @window_days

  @doc """
  Midnight UTC of the first date of a `days`-day window ending on `now`'s date, inclusive — the
  window is the `days` UTC dates up to and including today.
  """
  @spec window_start(pos_integer(), DateTime.t()) :: DateTime.t()
  def window_start(days, %DateTime{} = now) when is_integer(days) do
    now |> DateTime.to_date() |> Date.add(-(days - 1)) |> midnight()
  end

  @doc """
  The Usage tab's tiles and its people/agents chart over the last `range_days` days, for
  **counted users only** (not superadmins, not synthetic). `active_last_week` is the active count
  on today − 7 (the same weekday); `counted_users` counts every counted user, active or not.
  `series` has one entry per day, oldest first, ending today: `people` are users who visited that
  day, `agents` the owners whose boards had a run that day but who did not visit.
  """
  @spec overview(range(), DateTime.t()) :: overview()
  def overview(range_days, %DateTime{} = now) when range_days in @ranges do
    today = DateTime.to_date(now)
    users = counted_users()
    visit_days = visit_days(users, window_start(max(range_days, @window_days + 1), now))
    run_days = run_days(users, window_start(range_days, now))
    week = window_dates(@window_days, now)

    visitors = users_by_date(visit_days)
    runners = users_by_date(run_days)
    week_visits = Enum.filter(visit_days, &(&1.date in week))
    week_runs = Enum.filter(run_days, &(&1.date in week))

    %{
      active_today: visitors |> Map.get(today, MapSet.new()) |> MapSet.size(),
      active_last_week: visitors |> Map.get(Date.add(today, -7), MapSet.new()) |> MapSet.size(),
      this_week: distinct_users(week_visits),
      counted_users: Repo.aggregate(users, :count),
      agent_runs_7d: week_runs |> Enum.map(& &1.n) |> Enum.sum(),
      agent_run_owners_7d: distinct_users(week_runs),
      median_visit_seconds_7d: median_visit_seconds(users, window_start(@window_days, now), now),
      visits_per_active_day_7d: visits_per_active_day(week_visits),
      series:
        for date <- window_dates(range_days, now) do
          people = Map.get(visitors, date, MapSet.new())
          agents = runners |> Map.get(date, MapSet.new()) |> MapSet.difference(people)
          %{date: date, people: MapSet.size(people), agents: MapSet.size(agents)}
        end
    }
  end

  @doc """
  One row per non-synthetic user for the Usage table — superadmins included with
  `counted?: false` — sorted by `last_seen_at` descending (never-seen last), then `id`. The last
  board and card come from the visit with the greatest `last_at` (the card is the last of its
  `card_refs`). `strip` is `strip_days/0` day states, oldest first; the `_7d` figures cover
  `window_days/0`. Runs and shipped cards count on the owner of the card's (non-archived) board.
  """
  @spec user_rows(DateTime.t()) :: [user_row()]
  def user_rows(%DateTime{} = now) do
    users = listed_users()
    people = Repo.all(from u in users, select: %{id: u.id, name: u.name, email: u.email})
    visits = users |> visit_days(window_start(@strip_days, now)) |> Enum.group_by(& &1.user_id)
    runs = users |> run_days(window_start(@strip_days, now)) |> Enum.group_by(& &1.user_id)
    shipped = shipped_by_owner(users, now)
    last_seen = last_seen(users)

    people
    |> Enum.map(fn person ->
      activity = activity(Map.get(visits, person.id, []), Map.get(runs, person.id, []), now)
      last = Map.get(last_seen, person.id, %{last_at: nil, board_name: nil, card_refs: []})

      %{
        id: person.id,
        name: person.name,
        email: person.email,
        counted?: counted?(person.email),
        last_seen_at: last.last_at,
        last_board_name: last.board_name,
        last_card_ref: List.last(last.card_refs),
        strip: activity.strip,
        visits_7d: activity.visits_7d,
        seconds_7d: activity.seconds_7d,
        runs_7d: activity.runs_7d,
        shipped_7d: Map.get(shipped, person.id, 0)
      }
    end)
    |> Enum.sort_by(&{is_nil(&1.last_seen_at), &1.last_seen_at && -DateTime.to_unix(&1.last_seen_at), &1.id})
  end

  @doc """
  The Usage panel for one user: the `user_rows/1` figures plus `active_days_14` (distinct visit
  days in the strip), `waiting` (unarchived cards on their boards awaiting a human —
  `Schemas.Card.awaiting_human_statuses/0`), `board_count` (owned, non-archived boards) and the
  `@recent_visits` newest visits. `nil` for an unknown id or a synthetic user.
  """
  @spec user_detail(integer(), DateTime.t()) :: user_detail() | nil
  def user_detail(user_id, %DateTime{} = now) when is_integer(user_id) do
    users = where(listed_users(), [u], u.id == ^user_id)

    person =
      Repo.one(
        from u in users,
          left_join: b in subquery(owned_board_counts()),
          on: b.owner_id == u.id,
          select: %{id: u.id, name: u.name, email: u.email, inserted_at: u.inserted_at, board_count: coalesce(b.n, 0)}
      )

    if person, do: user_detail(person, users, now)
  end

  defp user_detail(person, users, now) do
    visits = visit_days(users, window_start(@strip_days, now))
    activity = activity(visits, run_days(users, window_start(@strip_days, now)), now)

    Map.merge(person, %{
      counted?: counted?(person.email),
      active_days_14: visits |> Enum.filter(&(&1.date in window_dates(@strip_days, now))) |> length(),
      visits_7d: activity.visits_7d,
      seconds_7d: activity.seconds_7d,
      runs_7d: activity.runs_7d,
      shipped_7d: users |> shipped_by_owner(now) |> Map.get(person.id, 0),
      waiting: waiting(person.id),
      strip: activity.strip,
      recent_visits: recent_visits(person.id)
    })
  end

  # -- users ---------------------------------------------------------------------------------------

  # Every non-synthetic user. `provider NOT IN (...)` alone drops NULL providers in SQL.
  defp listed_users do
    synthetic = User.synthetic_providers()
    from u in User, where: is_nil(u.provider) or u.provider not in ^synthetic
  end

  defp counted_users do
    superadmins = Scope.superadmin_emails()
    where(listed_users(), [u], u.email not in ^superadmins)
  end

  defp counted?(email), do: email not in Scope.superadmin_emails()

  # The owned, non-archived boards of `users`, as `(b, u)` bindings.
  defp owned_boards(users) do
    from b in Board, join: u in subquery(users), on: u.id == b.owner_id, where: is_nil(b.archived_at)
  end

  defp owned_board_counts do
    from b in Board, where: is_nil(b.archived_at), group_by: b.owner_id, select: %{owner_id: b.owner_id, n: count(b.id)}
  end

  # -- aggregates ----------------------------------------------------------------------------------

  # Visits since `since`, grouped by (user, UTC date of `started_at`).
  defp visit_days(users, since) do
    Repo.all(
      from v in UsageVisit,
        join: u in subquery(users),
        on: u.id == v.user_id,
        where: v.started_at >= ^since,
        group_by: [v.user_id, fragment("(?)::date", v.started_at)],
        select: %{
          user_id: v.user_id,
          date: fragment("(?)::date", v.started_at),
          n: count(v.id),
          seconds: type(coalesce(sum(v.seconds), 0), :integer)
        }
    )
  end

  # Runs since `since` on the owned, non-archived boards of `users`, grouped by (owner, UTC date of
  # `coalesce(started_at, inserted_at)`).
  defp run_days(users, since) do
    Repo.all(
      from [b, _u] in owned_boards(users),
        join: c in Card,
        on: c.board_id == b.id,
        join: r in Run,
        on: r.card_id == c.id,
        where: coalesce(r.started_at, r.inserted_at) >= type(^since, :utc_datetime),
        group_by: [b.owner_id, fragment("(?)::date", coalesce(r.started_at, r.inserted_at))],
        select: %{
          user_id: b.owner_id,
          date: fragment("(?)::date", coalesce(r.started_at, r.inserted_at)),
          n: count(r.id)
        }
    )
  end

  # Distinct cards per owner that *entered* a top-level Done stage of their board in the
  # `window_days/0` window: to Done and not from Done, so an in-place approve at Done never counts.
  # A NULL `from_stage_id` (pre-RE146 rows) is "not in Done".
  defp shipped_by_owner(users, now) do
    done_ids =
      from([b, _u] in owned_boards(users),
        join: s in Stage,
        on: s.board_id == b.id,
        where: is_nil(s.parent_id),
        select: s
      )
      |> Repo.all()
      |> Boards.top_level_done_stage_ids()

    from([b, _u] in owned_boards(users),
      join: c in Card,
      on: c.board_id == b.id,
      join: a in Activity,
      on: a.card_id == c.id,
      where: a.type in ^@shipped_types,
      where: a.inserted_at >= ^window_start(@window_days, now) and a.inserted_at < ^tomorrow(now),
      where: fragment("(?->>'to_stage_id')::bigint", a.meta) in ^done_ids,
      where: fragment("coalesce((?->>'from_stage_id')::bigint, 0)", a.meta) not in ^done_ids,
      group_by: b.owner_id,
      select: {b.owner_id, count(c.id, :distinct)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # The visit with the greatest `last_at` per user (all time), with its board's name.
  defp last_seen(users) do
    from(v in UsageVisit,
      join: u in subquery(users),
      on: u.id == v.user_id,
      left_join: b in Board,
      on: b.id == v.board_id,
      distinct: [asc: v.user_id],
      order_by: [desc: v.last_at],
      select: {v.user_id, %{last_at: v.last_at, board_name: b.name, card_refs: v.card_refs}}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp median_visit_seconds(users, since, now) do
    Repo.one(
      from v in UsageVisit,
        join: u in subquery(users),
        on: u.id == v.user_id,
        where: v.started_at >= ^since and v.started_at < ^tomorrow(now),
        select: type(fragment("percentile_disc(0.5) within group (order by ?)", v.seconds), :integer)
    )
  end

  defp waiting(user_id) do
    awaiting = Card.awaiting_human_statuses()

    Repo.aggregate(
      from(c in Card,
        join: b in Board,
        on: b.id == c.board_id,
        where: b.owner_id == ^user_id and is_nil(b.archived_at),
        where: is_nil(c.archived_at) and c.status in ^awaiting
      ),
      :count
    )
  end

  defp recent_visits(user_id) do
    Repo.all(
      from v in UsageVisit,
        left_join: b in Board,
        on: b.id == v.board_id,
        where: v.user_id == ^user_id,
        order_by: [desc: v.started_at, desc: v.id],
        limit: @recent_visits,
        select: %{id: v.id, started_at: v.started_at, seconds: v.seconds, board_name: b.name, card_refs: v.card_refs}
    )
  end

  # -- in-memory merge -----------------------------------------------------------------------------

  # One user's strip and `_7d` figures from their (user, date) visit and run rows.
  defp activity(visit_days, run_days, now) do
    week = window_dates(@window_days, now)
    visited = MapSet.new(visit_days, & &1.date)
    ran = MapSet.new(run_days, & &1.date)
    week_visits = Enum.filter(visit_days, &(&1.date in week))

    %{
      strip: Enum.map(window_dates(@strip_days, now), &day_state(&1 in visited, &1 in ran)),
      visits_7d: week_visits |> Enum.map(& &1.n) |> Enum.sum(),
      seconds_7d: week_visits |> Enum.map(& &1.seconds) |> Enum.sum(),
      runs_7d: run_days |> Enum.filter(&(&1.date in week)) |> Enum.map(& &1.n) |> Enum.sum()
    }
  end

  defp day_state(true, true), do: :both
  defp day_state(true, false), do: :human
  defp day_state(false, true), do: :agent
  defp day_state(false, false), do: :none

  defp users_by_date(rows) do
    Enum.reduce(rows, %{}, fn row, acc ->
      Map.update(acc, row.date, MapSet.new([row.user_id]), &MapSet.put(&1, row.user_id))
    end)
  end

  defp distinct_users(rows), do: rows |> MapSet.new(& &1.user_id) |> MapSet.size()

  # Visits per user-day: each (user, date) row is one active day.
  defp visits_per_active_day([]), do: nil
  defp visits_per_active_day(rows), do: (rows |> Enum.map(& &1.n) |> Enum.sum()) / length(rows)

  # The `days` UTC dates ending on `now`'s date, oldest first.
  defp window_dates(days, now), do: Date.range(DateTime.to_date(window_start(days, now)), DateTime.to_date(now))

  defp tomorrow(now), do: now |> DateTime.to_date() |> Date.add(1) |> midnight()

  defp midnight(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
end
