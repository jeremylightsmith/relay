defmodule Storybook.ValueStream.StreamBox do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias RelayWeb.ValueStreamLayout

  def function, do: &RelayWeb.ValueStreamComponents.stream_box/1
  def render_source, do: :function

  def template do
    """
    <div style="position:relative;width:200px;height:140px;">
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      box(:queue, state(1, "Next up", :queue, mean_secs: 64_800.0, wip: 7), :flow, %{}),
      box(
        :flow_with_rework,
        state(2, "Code", :flow,
          mean_secs: 7_200.0,
          mean_first_secs: 3_600.0,
          mean_visits: 2.0,
          mean_baton: %{agent: 5_400.0, human: 0.0, nobody: 1_800.0},
          mean_cost: Decimal.new("3.40")
        ),
        :flow,
        %{nodes: 21},
        "/storybook/value_stream/stream_box"
      ),
      box(
        :gate,
        state(3, "Review", :gate, mean_secs: 27_000.0, mean_first_secs: 27_000.0, approve_rate: 0.5),
        :flow,
        %{}
      ),
      box(:done_averaged, state(4, "Done", :done), :flow, %{cards_per_week: 14.0}),
      box(:done_in_progress, state(4, "Done", :done), :card, %{done_at: nil})
    ]
  end

  defp box(id, state, scope, extra, href \\ nil) do
    %Variation{
      id: id,
      attributes: %{
        box: %{state: state, x: 0, y: 0, w: 186, h: 132},
        rows: ValueStreamLayout.box_rows(state, scope, extra),
        href: href
      }
    }
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
