defmodule RelayWeb.Api.AuditController do
  @moduledoc """
  Read-only per-flow run-history audit findings (RE249) — the half of `relay audit` whose data
  lives only here. CI parity is computed in `bin/relay`, because the server has no checkout of
  any board's repo.
  """
  use RelayWeb, :controller

  alias Relay.Flows
  alias Relay.Runs

  action_fallback RelayWeb.Api.FallbackController

  def audit(conn, %{"key" => key} = params) do
    case Flows.get_flow(conn.assigns.current_board, key) do
      nil ->
        {:error, :not_found}

      flow ->
        window = window(params["window"])
        result = Runs.audit(flow, window: window)

        render(conn, :audit,
          flow_key: flow.key,
          window: window,
          runs: result.runs,
          findings: result.findings
        )
    end
  end

  # The response ECHOES the window, so it must echo the one actually used: `Relay.Runs`
  # normalizes garbage to the default internally, and the report header would otherwise quote a
  # window nobody queried.
  defp window(requested) do
    if requested in Runs.metric_windows(), do: requested, else: Runs.default_window()
  end
end
