defmodule HamacaWeb.Api.HarnessJSON do
  @moduledoc "Serializes `GET /api/harnesses`: each harness in `Hamaca.Agents.harness_wire/1` shape."

  alias Hamaca.Agents

  def index(%{harnesses: harnesses, digest: digest}) do
    %{harnesses: Enum.map(harnesses, &Agents.harness_wire/1), digest: digest}
  end
end
