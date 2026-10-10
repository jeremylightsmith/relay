defmodule Storybook.AgentsSettingsComponents.AgentsTable do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.AgentsSettingsComponents.agents_table/1
  def render_source, do: :function

  # Settings → Agents (RE433, card mockup 01): the default row, two counted rows and a red row
  # whose model left Gemini CLI's list.
  @claude %Schemas.Harness{id: 1, name: "Claude Code", models: ["opus", "sonnet", "haiku"]}
  @gemini %Schemas.Harness{id: 3, name: "Gemini CLI", models: ["gemini-2.5-flash"]}

  @agents [
    %Schemas.Agent{id: 1, name: "Claude Opus", model: "opus", harness_id: 1, harness: @claude},
    %Schemas.Agent{id: 2, name: "Claude Sonnet", model: "sonnet", harness_id: 1, harness: @claude},
    %Schemas.Agent{id: 3, name: "Claude Haiku", model: "haiku", harness_id: 1, harness: @claude},
    %Schemas.Agent{id: 4, name: "Gemini Pro", model: "gemini-2.5-pro", harness_id: 3, harness: @gemini}
  ]

  @usage %{
    "Claude Sonnet" => [{"code", "spec_review"}, {"code", "sync_fix"}, {"code", "acceptance"}, {"code", "post"}],
    "Claude Haiku" => [{"deploy", "notify"}]
  }

  def variations do
    [
      %Variation{
        id: :default,
        description: "Default badge, USED BY counts and a red MODEL REMOVED row",
        attributes: %{agents: @agents, default_agent_id: 1, usage: @usage}
      },
      %Variation{
        id: :read_only,
        description: "An archived board — no Make default / Edit",
        attributes: %{agents: @agents, default_agent_id: 1, usage: @usage, read_only?: true}
      }
    ]
  end
end
