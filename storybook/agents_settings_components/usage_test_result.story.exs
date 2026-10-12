defmodule Storybook.AgentsSettingsComponents.UsageTestResult do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.AgentsSettingsComponents.usage_test_result/1
  def render_source, do: :function

  # The harness form's TEST result row (RE436, card mockup 01): what the Claude Code seed rule
  # makes of a pasted line, straight from `Relay.Agents.try_usage_line/3`.
  @now ~U[2026-10-10 00:00:00Z]
  @allowed ~s({"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.42,"resetsAt":1791651000},"seven_day":{"utilization":0.18,"resetsAt":1792000000}}}})
  @over ~s({"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.95,"resetsAt":1791651000},"seven_day":{"utilization":0.18,"resetsAt":1792000000}}}})
  @rejected ~s({"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1791700000,"unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":1791651000}}}})

  defp try_line(line) do
    usage = Enum.find(Relay.Agents.seed_harnesses(), &(&1.key == "claude-code")).usage
    Relay.Agents.try_usage_line(usage, line, @now)
  end

  def variations do
    [
      %Variation{id: :not_paused, description: "✓ reading, not paused", attributes: %{result: try_line(@allowed)}},
      %Variation{id: :over, description: "✓ reading, a window over its pause at", attributes: %{result: try_line(@over)}},
      %Variation{
        id: :refused,
        description: "✓ reading, the harness refused a call",
        attributes: %{result: try_line(@rejected)}
      },
      %Variation{
        id: :not_a_reading,
        description: "✗ not a reading",
        attributes: %{result: try_line(~s({"type":"assistant"}))}
      },
      %Variation{id: :not_json, description: "✗ not valid JSON", attributes: %{result: try_line("not json")}}
    ]
  end
end
