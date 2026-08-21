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
      },
      %Variation{
        id: :actual_single,
        attributes: %{
          id: "vb-actual-single",
          mode: :actual,
          split: %{ok: 1, needs: 0, fail: 0, total: 1, ok_pct: 100, needs_pct: 0, fail_pct: 0}
        }
      },
      %Variation{
        id: :actual_mixed,
        attributes: %{
          id: "vb-actual-mixed",
          mode: :actual,
          split: %{ok: 2, needs: 0, fail: 1, total: 3, ok_pct: 67, needs_pct: 0, fail_pct: 33}
        }
      }
    ]
  end
end
