defmodule RelayWeb.Api.FlowJSON do
  @moduledoc """
  Renders flows as canonical `Relay.Flows.Document` documents (RLY-241), each with the
  read-only `"derived"` pickup / drop-off block beside it (RE429) and the read-only `"problem"`
  (RE430: `Relay.Flows.Shape.wire/1` of a broken board shape, `nil` when healthy) — `PUT`
  renders through `show/1` too, so a pull and a push response always carry the same shape.
  """

  alias Relay.Flows.Document
  alias Relay.Flows.Shape

  def index(%{flows: flows}), do: %{data: Enum.map(flows, &document/1)}

  def show(%{flow: flow}), do: %{data: document(flow)}

  defp document(flow) do
    flow
    |> Document.encode()
    |> Map.put("derived", Document.derived(flow))
    |> Map.put("problem", Shape.wire(flow.problem))
  end
end
