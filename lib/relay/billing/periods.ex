defmodule Relay.Billing.Periods do
  @moduledoc """
  The billing-date arithmetic of paying up front (RE460, ADR 0012): pure, no Repo. A port of
  Throughway's `Plans.Renewal`.

  An account pays one month up front on its own `billing_day` (1–31, the day of the month it
  first paid). A month shorter than that day renews on its last day. A period runs from its
  start to the day before the next month's renewal day.
  """

  @doc "The day an account on `billing_day` renews in `year`/`month`: that day, or the month's last."
  @spec renews_on(1..31, integer(), 1..12) :: Date.t()
  def renews_on(billing_day, year, month) when billing_day in 1..31 and month in 1..12 do
    Date.new!(year, month, min(billing_day, Date.days_in_month(Date.new!(year, month, 1))))
  end

  @doc "The period starting on `start`: `{start, the day before next month's renewal day}`."
  @spec period(Date.t(), 1..31) :: {Date.t(), Date.t()}
  def period(%Date{} = start, billing_day) when billing_day in 1..31 do
    %Date{year: year, month: month} = start |> Date.beginning_of_month() |> Date.shift(month: 1)
    {start, Date.add(renews_on(billing_day, year, month), -1)}
  end

  @doc """
  The start of the period `n` periods after the one starting on `start`, on `billing_day`
  (clamped to a short month's last day, as `renews_on/3`). `n = 0` is `start` itself.
  """
  @spec renewal_after(Date.t(), 1..31, non_neg_integer()) :: Date.t()
  def renewal_after(%Date{} = start, billing_day, 0) when billing_day in 1..31, do: start

  def renewal_after(%Date{} = start, billing_day, n) when billing_day in 1..31 and is_integer(n) and n > 0 do
    %Date{year: year, month: month} = start |> Date.beginning_of_month() |> Date.shift(month: n)
    renews_on(billing_day, year, month)
  end

  @doc "The renewal day after a period paid through `paid_through`."
  @spec next_renewal(Date.t()) :: Date.t()
  def next_renewal(%Date{} = paid_through), do: Date.add(paid_through, 1)

  @doc """
  The billing day a period starting on `start` keeps: the stored `billing_day` when `start` is
  that day's renewal in its month (a 31st renewing on Feb 28 stays the 31st), else `start.day`.
  """
  @spec kept_billing_day(1..31 | nil, Date.t()) :: 1..31
  def kept_billing_day(billing_day, %Date{} = start) when billing_day in 1..31 do
    if renews_on(billing_day, start.year, start.month) == start, do: billing_day, else: start.day
  end

  def kept_billing_day(nil, %Date{day: day}), do: day
end
