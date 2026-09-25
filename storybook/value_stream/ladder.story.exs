defmodule Storybook.ValueStream.Ladder do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias RelayWeb.ValueStreamLayout

  def function, do: &RelayWeb.ValueStreamComponents.ladder/1
  def render_source, do: :function

  def template do
    """
    <div style="position:relative;width:1044px;height:488px;">
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    items = ValueStreamLayout.ladder_items(ValueStreamLayout.boxes(states()))

    [
      %Variation{id: :in_stream, attributes: %{items: items, geometry: ValueStreamLayout.geometry(4)}},
      %Variation{
        id: :with_off_stream_time,
        attributes: %{items: items, geometry: ValueStreamLayout.geometry(4), outside: 3_600}
      }
    ]
  end

  defp states do
    [
      state(1, "Next up", :queue, mean_secs: 64_800.0, wip: 7),
      state(2, "Code", :flow,
        mean_secs: 7_200.0,
        mean_first_secs: 3_600.0,
        mean_visits: 2.0,
        mean_baton: %{agent: 5_400.0, human: 0.0, nobody: 1_800.0}
      ),
      state(3, "Review", :gate, mean_secs: 27_000.0, mean_first_secs: 18_000.0, approve_rate: 0.5, rework_target: 2),
      state(4, "Done", :done)
    ]
  end

  defp state(stage_id, name, kind, attrs \\ []) do
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
end
