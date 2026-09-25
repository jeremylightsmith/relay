defmodule RelayWeb.ValueStreamStates do
  @moduledoc """
  RE347 test data: the level-1 artboard's nine states as plain `Relay.ValueStream` per-state
  maps (stage ids 1–9), so the layout and components are tested without a database. Boundary
  checks are off — test-only support.
  """
  use Boundary, top_level?: true, check: [in: false, out: false]

  def state(stage_id, name, kind, attrs \\ []) do
    Map.merge(
      %{
        stage_id: stage_id,
        name: name,
        kind: kind,
        rework_target: nil,
        mean_secs: 0.0,
        mean_first_secs: 0.0,
        mean_visits: 1.0,
        mean_baton: %{agent: 0.0, human: 0.0, nobody: 0.0},
        mean_cost: nil,
        wip: 0,
        approve_rate: nil
      },
      Map.new(attrs)
    )
  end

  def re_states do
    [
      state(1, "Next up", :queue, mean_secs: 64_800.0, wip: 7),
      state(2, "Spec", :flow,
        mean_secs: 720.0,
        mean_first_secs: 360.0,
        mean_visits: 2.0,
        mean_baton: %{agent: 600.0, human: 0.0, nobody: 120.0},
        mean_cost: Decimal.new("0.30")
      ),
      state(3, "Spec · Review", :gate,
        mean_secs: 19_800.0,
        mean_first_secs: 19_800.0,
        approve_rate: 0.8,
        rework_target: 2
      ),
      state(4, "Spec · Done", :queue, mean_secs: 11_520.0),
      state(5, "Plan", :flow, mean_secs: 540.0, mean_first_secs: 540.0),
      state(6, "Plan · Done", :queue, mean_secs: 9_360.0),
      state(7, "Code", :flow, mean_secs: 7_200.0, mean_first_secs: 6_000.0),
      state(8, "Review", :gate, mean_secs: 27_000.0, mean_first_secs: 27_000.0, approve_rate: 0.5, rework_target: 7),
      state(9, "Done", :done)
    ]
  end

  def put_state(states, stage_id, attrs),
    do: Enum.map(states, &if(&1.stage_id == stage_id, do: Map.merge(&1, Map.new(attrs)), else: &1))
end
