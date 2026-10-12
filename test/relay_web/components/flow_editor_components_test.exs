defmodule RelayWeb.FlowEditorComponentsTest do
  @moduledoc """
  RE237 review fix (Task 6) — two inline `box-shadow`s in the flow editor mixed with
  `--color-base-content`, which is near-white (`oklch(0.96 0.006 255)`) under
  `data-theme="dark"`: the selected EFFORT segment and the active flow tab each rendered a
  light halo instead of a shadow. `--color-base-content`'s value also drifts by theme, so a
  literal alpha copied straight from the light-mode swept value drifted in light mode too
  (Rule N maps L 0.5 to P 70, so the alpha-faithful mix of the original `oklch(0.5 0.03 255 /
  0.12)` and `/ 0.14)` literals is ~10% either way, not the 12%/14% carried over verbatim).
  `commit_pill_shadow_test.exs` hit the identical defect earlier on this branch and fixed it
  with a dark-mode CSS override; these are inline styles (no selector to hang an override on),
  so the fix here is `--color-neutral`, which is `oklch(0.32 0.02 255)` — theme-invariant dark —
  in both theme blocks (app.css:95, :135).

  Also pins the field-hover shortcut (plan's exact-token table:
  `oklch(0.955-0.975 0.004-0.008 255)` -> `var(--color-field-hover)`) for the two
  `flow_editor_components.ex` sites whose literal was `oklch(0.96 0.004 255)` but got a
  computed mix instead of the shortcut.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RelayWeb.FlowEditorComponents

  defp agent_node(overrides) do
    Map.merge(
      %{
        key: "n",
        type: :agent,
        run: "go",
        llm: nil,
        effort: "high",
        max_retries: nil,
        timeout_minutes: nil,
        reads: [],
        writes: []
      },
      overrides
    )
  end

  defp inspector(node, opts \\ []) do
    assigns =
      Map.merge(
        %{node: node, edges: [], referenced_count: 0, read_only?: false, board_slug: "b"},
        Map.new(opts)
      )

    render_component(&FlowEditorComponents.node_inspector/1, assigns)
  end

  describe "agent binding field" do
    test "an agent node's inspector renders an editable agent field carrying the current value" do
      html = inspector(agent_node(%{agent: "plan-implementer"}))
      assert html =~ ~s(id="inspector-node-agent")
      # edits route through edit_node_field targeting the `agent` field
      assert html =~ ~s(name="field" value="agent")
      assert html =~ ~s(value="plan-implementer")
    end

    test "a generic agent node (no bound agent) renders an empty agent field" do
      html = inspector(agent_node(%{}))
      assert html =~ ~s(id="inspector-node-agent")
    end

    test "a non-agent node has no agent field" do
      shell = agent_node(%{type: :shell, agent: nil})
      html = inspector(shell)
      refute html =~ ~s(id="inspector-node-agent")
    end
  end

  describe "OUTGOING EDGES rows (RE330)" do
    @park_edge %{from: "n", to: "needs_input", on: :failed, max_loops: nil, when: nil}

    test "an interactive inspector renders each row as a select_edge button carrying the edge's original index" do
      html = inspector(agent_node(%{}), edges: [{@park_edge, 7}])
      assert html =~ ~s(id="inspector-out-edge-7")
      assert html =~ ~s(phx-click="select_edge")
      assert html =~ ~s(phx-value-index="7")
    end

    test "a read-only inspector renders the rows without phx-click" do
      html = inspector(agent_node(%{}), edges: [{@park_edge, 7}], read_only?: true)
      assert html =~ ~s(id="inspector-out-edge-7")
      refute html =~ ~s(phx-click="select_edge")
    end
  end

  describe "dark-mode-safe shadows" do
    test "the selected EFFORT segment's shadow mixes with --color-neutral, not --color-base-content" do
      html = inspector(agent_node(%{effort: "high"}))

      assert html =~
               "box-shadow:0 1px 2px color-mix(in oklab, var(--color-neutral) 10%, transparent)"

      refute html =~ "box-shadow:0 1px 2px color-mix(in oklab, var(--color-base-content)"
    end

    test "the active flow tab's shadow mixes with --color-neutral, not --color-base-content" do
      html =
        render_component(&FlowEditorComponents.flow_tabs/1, %{
          board_slug: "b",
          flow_key: "code",
          active: :editor
        })

      # 14, not 10: the artboard draws this tab and FlowMetricsLive's segmented control with the
      # byte-identical `oklch(0.5 0.03 255/0.14)`, so the two must carry the same alpha.
      assert html =~
               "box-shadow:0 1px 2px color-mix(in oklab, var(--color-neutral) 14%, transparent)"

      refute html =~ "box-shadow:0 1px 2px color-mix(in oklab, var(--color-base-content)"
    end
  end

  describe "field-hover shortcut" do
    test "the EFFORT segmented-control container uses the field-hover shortcut token" do
      html = inspector(agent_node(%{}))

      assert html =~
               "background:var(--color-field-hover);border:1px solid var(--color-field-border);border-radius:9px;padding:3px;gap:2px;align-self:flex-start;"
    end

    test "the outgoing-edge `on` chip uses the field-hover shortcut token" do
      html = inspector(agent_node(%{}), edges: [{%{on: :succeeded, to: "done", max_loops: nil}, 0}])

      assert html =~
               "background:var(--color-field-hover);color:color-mix(in oklab, var(--color-base-content) 70%, transparent);"
    end
  end

  describe "LLM picker (RE433)" do
    defp harnesses do
      [
        %Schemas.Harness{id: 1, key: "claude-code", name: "Claude Code", models: ["opus", "sonnet"]},
        %Schemas.Harness{id: 2, key: "codex", name: "Codex", models: ["gpt-6-sol"]}
      ]
    end

    defp agents do
      [cc, codex] = harnesses()

      [
        %Schemas.Agent{id: 11, name: "Claude Opus", model: "opus", harness_id: 1, harness: cc},
        %Schemas.Agent{id: 12, name: "Claude Sonnet", model: "sonnet", harness_id: 1, harness: cc},
        %Schemas.Agent{id: 13, name: "Codex Fast", model: "gpt-6-sol", harness_id: 2, harness: codex}
      ]
    end

    defp picker(node, opts \\ []) do
      [opus | _] = agents()

      node
      |> inspector([agents: agents(), harnesses: harnesses(), default_agent: opus] ++ opts)
      |> LazyHTML.from_fragment()
    end

    defp q(doc, sel), do: LazyHTML.query(doc, sel)
    defp text(el), do: el |> LazyHTML.text() |> String.trim()
    defp attr(el, name), do: el |> LazyHTML.attribute(name) |> List.first()

    test "8. the selected row is violet-tinted with a ● marker; the others show ○" do
      doc = picker(agent_node(%{llm: "Claude Sonnet"}))

      selected = q(doc, "#inspector-llm-12")
      assert attr(selected, "data-selected") == "true"
      assert attr(selected, "style") =~ "color-mix(in oklab, var(--color-secondary) 8%, var(--color-base-100))"
      assert selected |> q("[data-marker]") |> text() == "●"

      for id <- ["#inspector-llm-default", "#inspector-llm-11", "#inspector-llm-13"] do
        row = q(doc, id)
        refute attr(row, "data-selected") == "true"
        assert row |> q("[data-marker]") |> text() == "○"
      end
    end

    test "8. group headers carry bg-base-200 border-y border-base-300" do
      doc = picker(agent_node(%{llm: nil}))

      for key <- ["claude-code", "codex"] do
        class = doc |> q("#inspector-llm-group-#{key}") |> attr("class")
        assert class =~ "bg-base-200 border-y border-base-300"
      end
    end

    test "8. read-only disables every LLM row button" do
      doc = picker(agent_node(%{llm: nil}), read_only?: true)
      buttons = q(doc, "#inspector-llm button")

      assert Enum.count(buttons) == 4
      assert Enum.all?(buttons, &(attr(&1, "disabled") != nil))
    end
  end

  describe "ADD NODE palette (RE439)" do
    # Scenario 13
    test "lists every type in order, with fork / join glyphs on the control types" do
      doc = LazyHTML.from_fragment(render_component(&FlowEditorComponents.palette/1, %{}))

      assert doc |> LazyHTML.query("button") |> LazyHTML.attribute("id") ==
               ~w(palette-agent palette-shell palette-gate palette-fan_out palette-fan_in palette-human)

      assert doc |> LazyHTML.query(~s(#palette-fan_out svg[data-glyph="fan_out"])) |> Enum.count() == 1
      assert doc |> LazyHTML.query(~s(#palette-fan_in svg[data-glyph="fan_in"])) |> Enum.count() == 1
      assert doc |> LazyHTML.query("#palette-agent svg") |> Enum.count() == 0
      assert doc |> LazyHTML.query("#palette-parallel") |> Enum.count() == 0
    end
  end

  describe "fan-out inspector (RE439)" do
    alias Relay.FanOutFixtures

    defp fan_out_inspector(opts) do
      edges = FanOutFixtures.panel_edges()

      out_edges =
        edges |> Enum.with_index() |> Enum.filter(fn {e, _i} -> e.from == "fo" end)

      assigns =
        Map.merge(
          %{
            node: %{key: "fo", type: :fan_out, max_parallel: 2},
            region: Schemas.Flow.region(FanOutFixtures.panel_flow(), "fo"),
            out_edges: out_edges,
            edges: edges,
            nodes: FanOutFixtures.panel_nodes(),
            referenced_count: 4,
            read_only?: false
          },
          Map.new(opts)
        )

      LazyHTML.from_fragment(render_component(&FlowEditorComponents.fan_out_inspector/1, assigns))
    end

    defp fo_q(doc, sel), do: LazyHTML.query(doc, sel)
    defp fo_attr(el, name), do: el |> LazyHTML.attribute(name) |> List.first()

    # Scenario 12
    test "a read-only fan-out inspector disables the branch rows, the stepper and Reset" do
      doc = fan_out_inspector(read_only?: true)
      branches = fo_q(doc, "button[id^=inspector-branch-]")

      assert LazyHTML.attribute(branches, "id") == ~w(inspector-branch-a inspector-branch-b1 inspector-branch-c)
      assert Enum.all?(branches, &(fo_attr(&1, "phx-click") == nil))
      assert Enum.all?(branches, &(fo_attr(&1, "disabled") != nil))

      for id <- ~w(#inspector-max-parallel-dec #inspector-max-parallel-inc #inspector-max-parallel-reset) do
        assert fo_attr(fo_q(doc, id), "disabled") != nil, "expected #{id} disabled"
      end

      assert doc |> fo_q("#inspector-delete-guard") |> LazyHTML.text() =~ "Referenced by 4 edges"
    end

    # Scenario 13
    test "an interactive fan-out inspector links each branch to its edge and tints its bar by head type" do
      doc = fan_out_inspector(read_only?: false)
      c = fo_q(doc, "#inspector-branch-c")

      assert fo_attr(c, "phx-click") == "select_edge"
      assert fo_attr(c, "phx-value-index") == "4"

      assert doc |> fo_q("#inspector-shared-checkout") |> fo_attr("style") =~
               "color-mix(in oklab, var(--color-accent) 6%, var(--color-base-100))"

      assert doc |> fo_q("#inspector-branch-a [data-branch-bar]") |> fo_attr("style") =~
               "color-mix(in oklab, var(--color-base-content) 60%, var(--color-base-100))"

      assert doc |> fo_q("#inspector-branch-b1 [data-branch-bar]") |> fo_attr("style") =~ "var(--color-secondary)"
    end
  end

  describe "fan-in inspector (RE439)" do
    alias Relay.FanOutFixtures

    defp fan_in_inspector(assigns) do
      LazyHTML.from_fragment(render_component(&FlowEditorComponents.fan_in_inspector/1, assigns))
    end

    defp fi_text(doc, sel), do: doc |> LazyHTML.query(sel) |> LazyHTML.text() |> String.trim()

    # Task 3 scenario 6
    test "with no region it reads 0 branches and the empty line, and still renders RESOLVES" do
      doc = fan_in_inspector(%{node: %{key: "fi", type: :fan_in}, region: nil, edges: [], referenced_count: 0})

      assert fi_text(doc, "#inspector-waits-for-label") == "WAITS FOR · 0 BRANCHES"
      assert doc |> LazyHTML.query("#inspector-waits-for-empty") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#inspector-resolves") |> Enum.count() == 1
    end

    # Task 3 scenario 7
    test "colours the RESOLVES words and lists each branch's outcomes into the fan-in" do
      doc =
        fan_in_inspector(%{
          node: %{key: "fi", type: :fan_in},
          region: Schemas.Flow.region(FanOutFixtures.panel_flow(), "fo"),
          edges: FanOutFixtures.panel_edges(),
          referenced_count: 5
        })

      words = LazyHTML.query(doc, "#inspector-resolves [data-resolves-outcome]")
      [succeeded, failed] = Enum.to_list(words)

      assert String.trim(LazyHTML.text(succeeded)) == "succeeded"
      assert succeeded |> LazyHTML.attribute("style") |> List.first() =~ "color:var(--color-success)"
      assert String.trim(LazyHTML.text(failed)) == "failed"
      assert failed |> LazyHTML.attribute("style") |> List.first() =~ "color:var(--color-error)"
      assert fi_text(doc, "#inspector-wait-b1 [data-wait-outcomes]") == "succeeded"
    end
  end
end
