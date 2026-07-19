defmodule RelayWeb.Api.DiagnosisJSON do
  @moduledoc """
  Serializes `Relay.Runs.diagnose/3`. `detail`, and the nested
  `evidence.last_execution.detail`, are emitted **in full and never truncated** — the text
  that gets cut is precisely the failing review's findings an operator needs (RLY-177).
  """

  def show(%{diagnosis: %{verdict: verdict, detail: detail, evidence: evidence}}) do
    %{data: %{verdict: to_string(verdict), detail: detail, evidence: evidence}}
  end
end
