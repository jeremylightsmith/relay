defmodule Storybook.ExampleBoardComponents.NodePanel do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.ExampleBoardComponents.node_panel/1
  def render_source, do: :function

  # RE444: the example board's read-only node panel — an inline agent prompt on another
  # harness ("inline · no skill"), a shell command, and a control node (tag + key only).
  def variations do
    [
      %Variation{
        id: :inline_agent,
        description: "An agent node with no subagent: its prompt runs as written",
        attributes: %{
          flow_key: "three-brain-plan",
          node: %{
            key: "gpt_plan",
            type: :agent,
            agent: nil,
            llm: "GPT",
            run: "You are one of three planners working on {ref} independently.\n\nRead the card and write a plan."
          },
          agent: %{name: "GPT", harness: "Codex"}
        }
      },
      %Variation{
        id: :shell,
        description: "A shell node: its command, no model",
        attributes: %{
          flow_key: "implement",
          node: %{key: "validate", type: :shell, agent: nil, run: "npm test"},
          agent: nil
        }
      },
      %Variation{
        id: :control,
        description: "A fan-out control node has no run text",
        attributes: %{flow_key: "fan", node: %{key: "split", type: :fan_out, run: nil}, agent: nil}
      }
    ]
  end
end
