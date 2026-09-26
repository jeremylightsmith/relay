defmodule Storybook.ValueStream.FlowNodeBox do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.ValueStreamComponents.flow_node_box/1
  def render_source, do: :function

  def template do
    """
    <div style="position:relative;width:160px;height:150px;">
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :do,
        attributes: %{
          box:
            box("implement", :do, "agent", "×2.40", true, nil, [
              row("Work", "9.0m", :success),
              row("Wait", "1.2m", :warning),
              row("$ / run", "$1.58", :secondary)
            ])
        }
      },
      %Variation{
        id: :check,
        attributes: %{
          box:
            box("quality_review", :check, "agent", "×1.61", true, 62, [
              row("Work", "5.6m", :info),
              %{k: "Pass", v: "62%", tone: :error, bold: true},
              row("$ / run", "$0.39", :secondary)
            ])
        }
      },
      %Variation{
        id: :fix,
        attributes: %{
          box:
            "final_fix"
            |> box(:fix, "agent", "×0.43", false, nil, [
              %{k: "Rework", v: "6.4m", tone: :error, bold: true},
              %{k: "Laps", v: "55", tone: :error, bold: true},
              row("$ / lap", "$0.44", :secondary)
            ])
            |> Map.merge(%{x: 7, w: 136, h: 92})
        }
      }
    ]
  end

  defp box(key, role, type, visits, hot, pass, rows) do
    %{
      key: key,
      role: role,
      type: type,
      fix?: role == :fix,
      visits: visits,
      visits_hot: hot,
      pass_pct: pass,
      rows: rows,
      x: 0,
      y: 0,
      w: 150,
      h: 138
    }
  end

  defp row(k, v, tone), do: %{k: k, v: v, tone: tone, bold: false}
end
