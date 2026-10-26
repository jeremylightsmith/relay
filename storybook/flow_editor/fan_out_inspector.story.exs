defmodule Storybook.FlowEditor.FanOutInspector do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.FlowEditorComponents.fan_out_inspector/1
  def render_source, do: :function

  # RE439, card mockup "Editor — fan out / fan in as compact pills", section 1: the fan-out
  # inspector. A region inlined (test/support's Hamaca.FanOutFixtures isn't compiled in dev):
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
    %{from: "review_correctness", to: "fix_correctness", on: :failed},
    %{from: "fix_correctness", to: "review_correctness", on: :succeeded, max_loops: 2},
    %{from: "review_correctness", to: "review_join", on: :succeeded},
    %{from: "review_conventions", to: "review_join", on: :succeeded},
    %{from: "review_join", to: "done", on: :succeeded}
  ]

  def variations do
    # The invalid region: `review_conventions` never reaches the fan-in.
    open_edges = Enum.reject(@edges, &(&1.from == "review_conventions"))

    [
      %Variation{
        id: :unset,
        description: "MAX PARALLEL unset — every one of the 3 branches runs at once, so + is disabled",
        attributes: attributes(nil, @edges)
      },
      %Variation{
        id: :capped,
        description: "Capped at 2, with Reset shown; the correctness branch carries a loop",
        attributes: attributes(2, @edges)
      },
      %Variation{
        id: :invalid_region,
        description: "An invalid region — a branch never reaches the fan-in, so there's no join (`fan_in: nil`)",
        attributes: attributes(nil, open_edges)
      }
    ]
  end

  defp attributes(max_parallel, edges) do
    nodes = Enum.map(@nodes, &if(&1.key == "review_panel", do: %{&1 | max_parallel: max_parallel}, else: &1))
    working = %{nodes: nodes, edges: edges}

    %{
      node: Enum.find(nodes, &(&1.key == "review_panel")),
      region: Schemas.Flow.region(working, "review_panel"),
      out_edges: edges |> Enum.with_index() |> Enum.filter(fn {e, _i} -> e.from == "review_panel" end),
      edges: edges,
      nodes: nodes,
      referenced_count: 4
    }
  end
end
