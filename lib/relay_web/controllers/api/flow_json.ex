defmodule RelayWeb.Api.FlowJSON do
  @moduledoc """
  Renders flows as canonical `Relay.Flows.Document` documents (RLY-241), each with the
  read-only `"derived"` pickup / drop-off block beside it (RE429) — `PUT` renders through
  `show/1` too, so a pull and a push response always carry the same shape.
  """

  alias Relay.Flows.Document

  def index(%{flows: flows}), do: %{data: Enum.map(flows, &document/1)}

  def show(%{flow: flow}), do: %{data: document(flow)}

  defp document(flow), do: flow |> Document.encode() |> Map.put("derived", Document.derived(flow))
end
