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
        model: nil,
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
        %{node: node, edges: [], referenced_count: 0, read_only?: false},
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
      html = inspector(agent_node(%{}), edges: [%{on: :succeeded, to: "done", max_loops: nil}])

      assert html =~
               "background:var(--color-field-hover);color:color-mix(in oklab, var(--color-base-content) 70%, transparent);"
    end
  end
end
