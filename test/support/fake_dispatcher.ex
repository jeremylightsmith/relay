defmodule Relay.Runs.FakeDispatcher do
  @moduledoc """
  Test dispatcher: forwards dispatch/revoke to the process registered via
  `register/1`, so a test plays executor — receive `{:dispatched, job}` /
  `{:revoked, job}`, then drive `claim_job/report_outcome`.

  The dispatcher and its notification target ride on the calling process's `Relay.Runs.Instance`
  (ADR 0009 rule 1) — this used to be two `Application.put_env/3` calls plus an `on_exit` to undo
  them, which meant one test's dispatch notifications could be delivered to another test's pid.
  The instance registration is keyed by the test's pid and released when it exits, so there is
  nothing to clean up.

  `notify/1` runs inside the `RunServer`, which re-seeds `$callers` from the caller that started
  it, so the resolution lands on the right test.
  """

  @behaviour Relay.Runs.Dispatcher

  use Boundary, top_level?: true, check: [in: false, out: false]

  alias Relay.Runs.Instance

  @doc "Route this run's dispatch/revoke notifications to `pid` for the test's duration."
  def register(pid) when is_pid(pid) do
    Instance.register(%{dispatcher: __MODULE__, dispatcher_pid: pid})
  end

  @impl true
  def dispatch(job), do: notify({:dispatched, job})

  @impl true
  def revoke(job), do: notify({:revoked, job})

  defp notify(message) do
    case Instance.current().dispatcher_pid do
      nil -> :ok
      pid -> send(pid, message)
    end

    :ok
  end
end
