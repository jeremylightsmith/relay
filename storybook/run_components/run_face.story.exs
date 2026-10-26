defmodule Storybook.RunComponents.RunFace do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.RunComponents.run_face/1
  def render_source, do: :function

  # The running face's three treatments: working, stalled (inferred from silence), and rate
  # limited (RE320 — reported by the runner, so it outranks stalled).
  @running {:run, %{status: :running, node_index: 2, node_count: 4, current_node: "implement", flow_key: "code"}}

  # RE440: the card mockup's two face cards — an open fan-out region, then one with a branch
  # held back by max_parallel.
  @fan_out_open {:run,
                 %{
                   status: :running,
                   node_index: 3,
                   node_count: 6,
                   current_node: "fan_reviews",
                   flow_key: "code",
                   branches: %{
                     total: 3,
                     ended: 1,
                     running: 2,
                     queued: 0,
                     parked: 0,
                     succeeded: 1,
                     failed: 0,
                     bars: [:succeeded, :running, :running]
                   }
                 }}

  @fan_out_queued {:run,
                   %{
                     status: :running,
                     node_index: 3,
                     node_count: 6,
                     current_node: "fan_reviews",
                     flow_key: "code",
                     branches: %{
                       total: 3,
                       ended: 0,
                       running: 2,
                       queued: 1,
                       parked: 0,
                       succeeded: 0,
                       failed: 0,
                       bars: [:running, :running, :queued]
                     }
                   }}

  def variations do
    [
      %Variation{id: :running, attributes: %{ref: "RLY-20", run: @running}},
      %Variation{id: :stalled, attributes: %{ref: "RLY-21", run: @running, stalled?: true}},
      %Variation{
        id: :rate_limited,
        attributes: %{ref: "RLY-22", run: @running, rate_limited: %{resumes_at: ~U[2026-09-14 15:40:00Z]}}
      },
      %Variation{id: :fan_out_open, attributes: %{ref: "RLY-23", run: @fan_out_open}},
      %Variation{id: :fan_out_queued, attributes: %{ref: "RLY-24", run: @fan_out_queued}}
    ]
  end
end
