defmodule RelayWeb.Api.FlowJSON do
  @moduledoc "Renders flows as canonical `Relay.Flows.Document` documents (RLY-241)."

  alias Relay.Flows.Document

  def index(%{flows: flows}), do: %{data: Enum.map(flows, &Document.encode/1)}

  def show(%{flow: flow}), do: %{data: Document.encode(flow)}
end
