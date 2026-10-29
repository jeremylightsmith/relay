defmodule Hamaca.Talk.PinReaper do
  @moduledoc """
  The Talk pin clock (RE493): a supervised GenServer whose periodic (30s) sweep calls
  `Hamaca.Talk.release_gone_pins/1`, so a turn already `:queued` on a runner that has since
  gone is released to any runner within one interval instead of waiting forever. The Talk
  counterpart of `Hamaca.Runs.RunnerReaper` — it lives here, not in that sweep, because
  `Hamaca.Runs` may not depend on `Hamaca.Talk`. It holds no state beyond its timer, and its
  first tick is one interval after boot. Started with the runs engine (off in test).
  """
  use GenServer

  @default_interval_ms to_timeout(second: 30)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    Hamaca.Runs.Instance.adopt_callers(opts)
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    {:ok, %{interval: interval}, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    Process.send_after(self(), :sweep, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    Hamaca.Talk.release_gone_pins(nil)
    Process.send_after(self(), :sweep, state.interval)
    {:noreply, state}
  end
end
