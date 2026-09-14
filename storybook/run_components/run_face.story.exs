defmodule Storybook.RunComponents.RunFace do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.RunComponents.run_face/1
  def render_source, do: :function

  # The running face's three treatments: working, stalled (inferred from silence), and rate
  # limited (RE320 — reported by the runner, so it outranks stalled).
  @running {:run, %{status: :running, node_index: 2, node_count: 4, current_node: "implement", flow_key: "code"}}

  def variations do
    [
      %Variation{id: :running, attributes: %{ref: "RLY-20", run: @running}},
      %Variation{id: :stalled, attributes: %{ref: "RLY-21", run: @running, stalled?: true}},
      %Variation{
        id: :rate_limited,
        attributes: %{ref: "RLY-22", run: @running, rate_limited: %{resumes_at: ~U[2026-09-14 15:40:00Z]}}
      }
    ]
  end
end
