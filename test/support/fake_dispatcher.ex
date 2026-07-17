defmodule Relay.Runs.FakeDispatcher do
  @moduledoc """
  Test dispatcher: forwards dispatch/revoke to the process registered via
  `register/1`, so a test plays executor — receive `{:dispatched, job}` /
  `{:revoked, job}`, then drive `claim_job/start_job/report_outcome`.
  """

  @behaviour Relay.Runs.Dispatcher

  use Boundary, top_level?: true, check: [in: false, out: false]

  @doc "Route this run's dispatch/revoke notifications to `pid` for the test's duration."
  def register(pid) do
    Application.put_env(:relay, :runs_dispatcher, __MODULE__)
    Application.put_env(:relay, :runs_fake_dispatcher_pid, pid)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:relay, :runs_dispatcher)
      Application.delete_env(:relay, :runs_fake_dispatcher_pid)
    end)
  end

  @impl true
  def dispatch(job), do: notify({:dispatched, job})

  @impl true
  def revoke(job), do: notify({:revoked, job})

  defp notify(message) do
    case Application.get_env(:relay, :runs_fake_dispatcher_pid) do
      nil -> :ok
      pid -> send(pid, message)
    end

    :ok
  end
end
