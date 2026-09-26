defmodule Storybook.ValueStream.FlowMap do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias RelayWeb.ValueStreamFlowLayout, as: FlowLayout

  def function, do: &RelayWeb.ValueStreamComponents.flow_map/1
  def render_source, do: :function

  def template do
    """
    <div style="position:relative;width:3496px;height:692px;">
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    layout = FlowLayout.layout(code_flow())
    stream = %{runs: 12, done_runs: 11, parked_runs: 1}

    [
      %Variation{
        id: :code_flow,
        attributes: %{
          layout: layout,
          arcs: FlowLayout.arcs(layout, sends()),
          queue: FlowLayout.queue(:exclusive, %{mean_secs: 144, jobs: 12}),
          terminals: FlowLayout.terminals(layout, stream, "Review")
        }
      }
    ]
  end

  defp code_flow do
    attrs = Enum.find(Relay.Flows.DefaultLibrary.all(), &(&1.key == "code"))
    %Schemas.Flow{board_id: 0} |> Schemas.Flow.changeset(attrs) |> Ecto.Changeset.apply_action!(:build)
  end

  defp sends do
    [
      send("acceptance", "final_fix", "precommit", 3, 2_400),
      send("smoke", "final_fix", "precommit", 4, 3_000),
      send("quality_review", "fix_findings", "spec_review", 8, 1_900),
      send("spec_review", "fix_findings", "spec_review", 5, 900),
      send("sync", "sync_fix", "precommit", 1, 240),
      send("reverify", "resync_fix", "reverify", 1, 360),
      send("deploy", "github_fix", "resync", 2, 960),
      send("merge", "resync", "merge", 1, 60)
    ]
  end

  defp send(from, to, returns_to, laps, secs),
    do: %{from: from, to: to, returns_to: returns_to, laps: laps, to_secs: secs, rewind_secs: 0, secs: secs}
end
