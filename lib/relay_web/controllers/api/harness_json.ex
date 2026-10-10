defmodule RelayWeb.Api.HarnessJSON do
  @moduledoc "Serializes `GET /api/harnesses`: each harness in `Relay.Agents.harness_wire/1` shape."

  alias Relay.Agents

  def index(%{harnesses: harnesses, digest: digest}) do
    %{harnesses: Enum.map(harnesses, &Agents.harness_wire/1), digest: digest}
  end
end
