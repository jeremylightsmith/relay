defmodule Hamaca.Cards.DoneWeeks do
  @moduledoc """
  ISO-week math for the board's terminal Done column (RE504): pure, no Repo. The Done column
  pages by whole weeks of **effective done time** (`Schemas.Card.done_time/1`, `done_at ||
  updated_at`), read in the viewer's time zone — a week starts Monday 00:00 local.

  `Hamaca.Cards`' Done queries hand week starts (`Date`s) to `cutoff/2` to get the instant a
  week begins, so the "Monday midnight in this zone, as UTC" conversion lives here only.
  """

  alias Schemas.Card

  @utc "Etc/UTC"

  @doc """
  The zone to bucket in: `zone` when it is a name the time zone database (`Tz`) knows, else
  `"Etc/UTC"`. Accepts anything (`nil`, `""`, an unknown name, a non-binary) and never raises.
  """
  @spec zone(term()) :: String.t()
  def zone(zone) when is_binary(zone) and zone != "" do
    case DateTime.now(zone) do
      {:ok, _now} -> zone
      {:error, _reason} -> @utc
    end
  end

  def zone(_other), do: @utc

  @doc "The Monday of the ISO week containing `instant`, read in `zone`."
  @spec week_start(DateTime.t(), String.t()) :: Date.t()
  def week_start(%DateTime{} = instant, zone) do
    instant
    |> DateTime.shift_zone!(zone)
    |> DateTime.to_date()
    |> Date.beginning_of_week(:monday)
  end

  @doc """
  The UTC instant at which the week starting `monday` begins in `zone`: Monday 00:00:00 local.
  When midnight falls in a DST gap it is the first instant after the gap; when midnight is
  ambiguous it is the earlier of the two.
  """
  @spec cutoff(Date.t(), String.t()) :: DateTime.t()
  def cutoff(%Date{} = monday, zone) do
    local =
      case DateTime.new(monday, ~T[00:00:00], zone) do
        {:ok, local} -> local
        {:gap, _just_before, just_after} -> just_after
        {:ambiguous, first, _second} -> first
      end

    DateTime.shift_zone!(local, @utc)
  end

  @doc """
  The Done column's week marker for the week starting `start`, as seen at `now` in `zone`:
  `"This week"` / `"Last week"` carry the week's `range_label/2` as `range`; any older week is
  titled by its range alone (`range: nil`).
  """
  @spec label(Date.t(), DateTime.t(), String.t()) :: %{title: String.t(), range: String.t() | nil}
  def label(%Date{} = start, %DateTime{} = now, zone) do
    this_week = week_start(now, zone)
    today = now |> DateTime.shift_zone!(zone) |> DateTime.to_date()
    range = range_label(start, today)

    cond do
      start == this_week -> %{title: "This week", range: range}
      start == Date.add(this_week, -7) -> %{title: "Last week", range: range}
      true -> %{title: range, range: nil}
    end
  end

  @doc """
  The week starting `start` as a short range: `"Oct 12 – 18"`, `"Sep 28 – Oct 4"` across months,
  `"Dec 22 – 28, 2025"` when the week's Sunday is in another year than `today`, and
  `"Dec 29, 2025 – Jan 4, 2026"` for a week spanning years (whenever either year differs from
  `today`'s). En dash (U+2013) with a space each side; 3-letter English month abbreviations.
  """
  @spec range_label(Date.t(), Date.t()) :: String.t()
  def range_label(%Date{} = start, %Date{} = today) do
    sunday = Date.add(start, 6)

    cond do
      start.year != sunday.year ->
        "#{month_day(start)}, #{start.year} – #{month_day(sunday)}, #{sunday.year}"

      start.month == sunday.month ->
        "#{month_day(start)} – #{sunday.day}" <> year_suffix(sunday, today)

      true ->
        "#{month_day(start)} – #{month_day(sunday)}" <> year_suffix(sunday, today)
    end
  end

  @doc """
  Buckets `cards` (already ordered by effective done time, newest first) into
  `{week_start, cards}` pairs by `week_start(Card.done_time(card), zone)`, newest week first,
  keeping the input order within each week.
  """
  @spec group([Card.t()], String.t()) :: [{Date.t(), [Card.t()]}]
  def group(cards, zone) when is_list(cards) do
    cards
    |> Enum.group_by(&week_start(Card.done_time(&1), zone))
    |> Enum.sort_by(fn {week, _cards} -> week end, {:desc, Date})
  end

  defp month_day(%Date{} = date), do: Calendar.strftime(date, "%b ") <> Integer.to_string(date.day)

  defp year_suffix(%Date{year: year}, %Date{year: year}), do: ""
  defp year_suffix(%Date{year: year}, _today), do: ", #{year}"
end
