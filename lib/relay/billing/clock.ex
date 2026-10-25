defmodule Relay.Billing.Clock do
  @moduledoc """
  The billing clock (RE460, ADR 0012): an hourly ticker that runs `Relay.Billing.run_clock/2`
  for today's UTC date — resolving unanswered charges, renewals, then the once-only billing emails
  (`Relay.Billing.Notifier.notify_due/1`) — with `final_pass?` from `final_pass_hour/0` on, so a
  declined renewal gets its one retry at the end of its grace day. (A Free account is never
  charged by the clock; there is no launch backfill — RE469.)

  - Every tick takes a Postgres advisory lock (`lock_key/0`) inside `Repo.checkout/1`, so a
    multi-node deploy never double-runs and lock and unlock land on one connection.
  - The tick rescues, and `run_clock/2` isolates each account, so a DB blip cannot crash-loop
    the GenServer and one broken account never blocks the rest.

  Supervised with `enabled: Relay.Billing.enabled?()` — false in test and on a self-hosted
  install, when no tick is ever scheduled; the suite drives `run_clock/2` directly.
  """

  use GenServer

  alias Relay.Billing
  alias Relay.Repo

  require Logger

  @interval_ms to_timeout(hour: 1)
  # A crash-and-restart loop must not become a hot loop: the first tick waits too.
  @first_tick_ms 5_000
  # Arbitrary but fixed, and distinct from every other advisory lock.
  @lock_key 4_602_026
  @final_pass_hour 23

  @doc "The Postgres advisory lock key a tick holds."
  @spec lock_key() :: integer()
  def lock_key, do: @lock_key

  @doc "The UTC hour from which a tick is the day's final pass (the grace day's one retry)."
  @spec final_pass_hour() :: 23
  def final_pass_hour, do: @final_pass_hour

  @doc "Starts the clock. Options: `:enabled` (default true), `:interval_ms` (default one hour), `:name`."
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, true)

    {:ok,
     %{
       enabled: enabled,
       interval: Keyword.get(opts, :interval_ms, @interval_ms),
       timer: if(enabled, do: schedule(@first_tick_ms))
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    tick_rescued()
    {:noreply, %{state | timer: if(state.enabled, do: schedule(state.interval))}}
  end

  defp schedule(ms), do: Process.send_after(self(), :tick, ms)

  defp tick_rescued do
    tick()
  rescue
    error -> Logger.error("Billing.Clock: tick failed. " <> Exception.format(:error, error, __STACKTRACE__))
  end

  # Claims the advisory lock, then runs the clock for today. `:skipped` when another node holds it.
  defp tick do
    Repo.checkout(fn ->
      if lock?() do
        try do
          {:ok, Billing.run_clock(Date.utc_today(), final_pass?: DateTime.utc_now().hour >= @final_pass_hour)}
        after
          unlock()
        end
      else
        :skipped
      end
    end)
  end

  defp lock? do
    %{rows: [[locked?]]} = Repo.query!("SELECT pg_try_advisory_lock($1)", [@lock_key])
    locked?
  end

  defp unlock, do: Repo.query!("SELECT pg_advisory_unlock($1)", [@lock_key])
end
