defmodule Storybook.FlowEditor.FanInInspector do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.FlowEditorComponents.fan_in_inspector/1
  def render_source, do: :function

  # RE439, card mockup "Editor — fan out / fan in as compact pills", section 2: the fan-in
  # inspector. A region inlined (test/support's Relay.FanOutFixtures isn't compiled in dev):
  # review_panel ⇉ security / correctness ⇄ fix / conventions → review_join.
  @nodes [
    %{key: "prep", type: :shell},
    %{key: "review_panel", type: :fan_out, max_parallel: nil},
    %{key: "review_security", type: :agent},
    %{key: "review_correctness", type: :agent},
    %{key: "fix_correctness", type: :agent},
    %{key: "review_conventions", type: :shell},
    %{key: "review_join", type: :fan_in}
  ]

  @edges [
    %{from: "start", to: "prep"},
    %{from: "prep", to: "review_panel", on: :succeeded},
    %{from: "review_panel", to: "review_security"},
    %{from: "review_panel", to: "review_correctness"},
    %{from: "review_panel", to: "review_conventions"},
    %{from: "review_security", to: "review_join", on: :succeeded},
    %{from: "review_security", to: "review_join", on: :failed},
    %{from: "review_correctness", to: "fix_correctness", on: :failed},
    %{from: "fix_correctness", to: "review_correctness", on: :succeeded, max_loops: 2},
    %{from: "review_correctness", to: "review_join", on: :succeeded},
    %{from: "review_conventions", to: "review_join", on: :succeeded},
    %{from: "review_join", to: "done", on: :succeeded}
  ]

  def variations do
    working = %{nodes: @nodes, edges: @edges}

    [
      %Variation{
        id: :valid_join,
        description: "A valid 3-branch join; the security branch reaches it on succeeded / failed",
        attributes: %{
          node: Enum.find(@nodes, &(&1.key == "review_join")),
          region: Enum.find(Schemas.Flow.regions(working), &(&1.fan_in == "review_join")),
          edges: @edges,
          nodes: @nodes,
          referenced_count: 5
        }
      },
      %Variation{
        id: :no_region,
        description: "No fan-out closes here (or its region is invalid) — the unsaved bar says why",
        attributes: %{
          node: Enum.find(@nodes, &(&1.key == "review_join")),
          region: nil,
          edges: @edges,
          nodes: @nodes,
          referenced_count: 5
        }
      }
    ]
  end
end
