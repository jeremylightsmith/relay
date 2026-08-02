defmodule RelayWeb.Api.AuditJSON do
  @moduledoc "Renders `Relay.Runs.Audit` findings (RE249)."

  def audit(%{flow_key: flow_key, window: window, runs: runs, findings: findings}) do
    %{
      data: %{
        flow_key: flow_key,
        window: window,
        runs: runs,
        findings: Enum.map(findings, &finding/1)
      }
    }
  end

  # `severity` and `check` cross the wire as strings. The severity SET is pinned by
  # test/fixtures/executor_contract.json; check ids deliberately are not — bin/relay prints them
  # opaquely and must never branch on them, so the server can add a check without an
  # executor bump.
  defp finding(finding) do
    %{
      severity: Atom.to_string(finding.severity),
      check: Atom.to_string(finding.check),
      flow_key: finding.flow_key,
      node_key: finding.node_key,
      run_id: finding.run_id,
      summary: finding.summary,
      evidence: finding.evidence,
      fix: finding.fix
    }
  end
end
