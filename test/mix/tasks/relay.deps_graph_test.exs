defmodule Mix.Tasks.Relay.DepsGraphTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Relay.DepsGraph

  describe "dot_to_mermaid/1" do
    test "renders a fenced mermaid flowchart with the boundary edges" do
      dot = """
      digraph {
        label="Relay boundary";
        rankdir=LR;

        "Cards" [shape=box];
        "Repo" [shape=box];

        "Cards" -> "Repo";
      }
      """

      mermaid = DepsGraph.dot_to_mermaid(dot)

      assert mermaid =~ "```mermaid"
      assert mermaid =~ "flowchart LR"
      assert mermaid =~ "Cards --> Repo"
      assert String.ends_with?(mermaid, "```")
    end

    test "keeps isolated nodes that appear in no edge" do
      dot = """
      digraph {
        "Mailer" [shape=box];
        "Cards" [shape=box];
        "Repo" [shape=box];

        "Cards" -> "Repo";
      }
      """

      mermaid = DepsGraph.dot_to_mermaid(dot)

      assert mermaid =~ ~r/^\s{4}Mailer$/m
    end

    test "sanitizes node names that are not valid mermaid ids into id+label form" do
      dot = ~s|digraph { "Relay.Application" -> "RelayWeb"; }|

      mermaid = DepsGraph.dot_to_mermaid(dot)

      assert mermaid =~ ~s|Relay_Application["Relay.Application"]|
      assert mermaid =~ "Relay_Application --> RelayWeb"
    end

    test "output is deterministic regardless of edge order in the source" do
      a = ~s|digraph { "B" -> "C"; "A" -> "B"; }|
      b = ~s|digraph { "A" -> "B"; "B" -> "C"; }|

      assert DepsGraph.dot_to_mermaid(a) == DepsGraph.dot_to_mermaid(b)
    end
  end

  describe "splice/2" do
    test "replaces content between the generated markers, preserving the rest" do
      doc = """
      # Heading

      intro paragraph

      <!-- BEGIN generated: boundary-graph -->
      stale content
      <!-- END generated: boundary-graph -->

      outro paragraph
      """

      assert {:ok, spliced} = DepsGraph.splice(doc, "fresh body")

      assert spliced =~ "intro paragraph"
      assert spliced =~ "outro paragraph"
      assert spliced =~ "fresh body"
      refute spliced =~ "stale content"
      assert spliced =~ "<!-- BEGIN generated: boundary-graph -->"
      assert spliced =~ "<!-- END generated: boundary-graph -->"
    end

    test "returns :error when the markers are absent" do
      assert :error = DepsGraph.splice("no markers here", "body")
    end
  end
end
