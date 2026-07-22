defmodule Storybook.FlowMetrics.VerdictBar do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.FlowMetricsComponents.verdict_bar/1

  def variations do
    [
      %Variation{
        id: :mostly_ok,
        attributes: %{
          id: "vb-ok",
          split: %{ok: 92, needs: 3, fail: 5, total: 100, ok_pct: 92, needs_pct: 3, fail_pct: 5}
        }
      },
      %Variation{
        id: :hotspot,
        attributes: %{
          id: "vb-fail",
          split: %{ok: 59, needs: 2, fail: 39, total: 100, ok_pct: 59, needs_pct: 2, fail_pct: 39}
        }
      }
    ]
  end
end
