defmodule Mix.Tasks.Relay.GenStateTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Relay.GenState
  alias Relay.Runs.Transitions

  describe "render/1" do
    test "renders a markdown table with a header and one row per edge" do
      table = GenState.render([{:running, :parked, "park"}, {:failed, :running, "retry"}])

      assert table =~ "| From | To | Meaning |"
      assert table =~ "| --- | --- | --- |"
      assert table =~ "| `running` | `parked` | park |"
      assert table =~ "| `failed` | `running` | retry |"
    end

    test "row order is deterministic regardless of source order" do
      a = GenState.render([{:parked, :running, "resume"}, {:running, :done, "finish"}])
      b = GenState.render([{:running, :done, "finish"}, {:parked, :running, "resume"}])

      assert a == b
    end

    test "renders the live Transitions graph (every edge appears)" do
      table = GenState.render(Transitions.transitions())

      for {from, to, _meaning} <- Transitions.transitions() do
        assert table =~ "| `#{from}` | `#{to}` |"
      end
    end
  end

  describe "splice/2" do
    test "replaces only the marked block, preserving the rest" do
      doc = """
      # State

      <!-- BEGIN generated: run-transitions -->
      stale
      <!-- END generated: run-transitions -->

      outro
      """

      assert {:ok, spliced} = GenState.splice(doc, "fresh table")

      assert spliced =~ "# State"
      assert spliced =~ "outro"
      assert spliced =~ "fresh table"
      refute spliced =~ "stale"
      assert spliced =~ "<!-- BEGIN generated: run-transitions -->"
      assert spliced =~ "<!-- END generated: run-transitions -->"
    end

    test "returns :error when the markers are absent" do
      assert :error = GenState.splice("no markers here", "body")
    end
  end

  describe "the committed state.md is in sync with the live graph (drift gate)" do
    test "the run-transitions block matches what Transitions currently renders" do
      doc = File.read!("docs/architecture/state.md")
      {:ok, expected} = GenState.splice(doc, GenState.render(Transitions.transitions()))

      assert doc == expected,
             "docs/architecture/state.md is out of date — run `mix relay.gen_state` and commit the result."
    end
  end
end
