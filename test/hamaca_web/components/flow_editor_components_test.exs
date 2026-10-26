defmodule HamacaWeb.FlowEditorComponentsTest do
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
  use HamacaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias HamacaWeb.FlowEditorComponents

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
    alias Hamaca.FanOutFixtures

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
    alias Hamaca.FanOutFixtures

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

  describe "prompt preview and sheet (RE459)" do
    defp doc(html), do: LazyHTML.from_fragment(html)
    defp present?(doc, sel), do: doc |> LazyHTML.query(sel) |> Enum.count() > 0
    defp text_of(doc, sel), do: doc |> LazyHTML.query(sel) |> LazyHTML.text() |> String.trim()
    defp squish(text), do: text |> String.split() |> Enum.join(" ")

    defp classes(doc, sel) do
      doc |> LazyHTML.query(sel) |> LazyHTML.attribute("class") |> List.first("") |> String.split()
    end

    defp inner_html(doc, sel), do: doc |> LazyHTML.query(sel) |> LazyHTML.to_html()

    defp sheet(node, mode, opts \\ []) do
      assigns = Map.merge(%{node: node, mode: mode}, Map.new(opts))
      doc(render_component(&FlowEditorComponents.prompt_sheet/1, assigns))
    end

    @md_prompt "- one\n- two {ref}"

    # Scenario 1
    test "prompt_count/1 formats chars with a thousands separator and counts lines" do
      line = String.duplicate("a", 208)
      text = Enum.join(List.duplicate(line, 8), "\n") <> "\n" <> String.duplicate("a", 1880 - 8 * 208 - 8)
      assert String.length(text) == 1880
      assert length(String.split(text, "\n")) == 9

      assert FlowEditorComponents.prompt_count(text) == "1,880 chars · 9 lines"
    end

    # Scenario 2
    test "prompt_count/1 uses the singular at exactly one and reads zero for nil or empty" do
      assert FlowEditorComponents.prompt_count("x") == "1 char · 1 line"
      assert FlowEditorComponents.prompt_count("") == "0 chars · 0 lines"
      assert FlowEditorComponents.prompt_count(nil) == "0 chars · 0 lines"
      assert FlowEditorComponents.prompt_count("a\nb") == "3 chars · 2 lines"
    end

    # Scenario 3
    test "prompt_mode/1 renders agent prompts as markdown and everything else as code" do
      assert FlowEditorComponents.prompt_mode(:agent) == :markdown
      assert FlowEditorComponents.prompt_mode(:shell) == :code
      assert FlowEditorComponents.prompt_mode(:gate) == :code
      assert FlowEditorComponents.prompt_mode(:human) == :code
    end

    # Scenario 4
    test "an agent node's inspector shows a rendered markdown preview with count, Expand and Edit" do
      d = doc(inspector(agent_node(%{run: @md_prompt})))

      refute present?(d, "textarea")
      refute present?(d, "#inspector-node-form")

      body_classes = classes(d, "#inspector-prompt-preview-body")
      assert "prompt-preview" in body_classes
      assert "md" in body_classes
      body = inner_html(d, "#inspector-prompt-preview-body")
      assert body =~ "<li>"
      assert body =~ ~s(<span class="prompt-placeholder">{ref}</span>)
      assert d |> LazyHTML.query("#inspector-prompt-preview-body") |> LazyHTML.attribute("phx-hook") == ["PromptClamp"]

      preview = LazyHTML.query(d, "#inspector-prompt-preview")
      assert LazyHTML.attribute(preview, "role") == ["button"]
      assert LazyHTML.attribute(preview, "tabindex") == ["0"]
      assert LazyHTML.attribute(preview, "phx-click") == ["open_prompt_sheet"]
      assert LazyHTML.attribute(preview, "phx-value-mode") == ["read"]
      assert LazyHTML.attribute(preview, "title") == ["Open the full prompt"]

      for c <- ~w(text-left border border-base-300 rounded-lg hover:border-base-content/30 bg-base-100 cursor-zoom-in) do
        assert c in classes(d, "#inspector-prompt-preview"), "expected #{c} on the preview box"
      end

      assert text_of(d, "#inspector-prompt-count") == "17 chars · 2 lines"
      assert "font-mono" in classes(d, "#inspector-prompt-count")
      assert "text-base-content/60" in classes(d, "#inspector-prompt-count")

      assert present?(d, "#inspector-prompt-expand")
      assert ~w(btn btn-sm btn-outline flex-1) -- classes(d, "#inspector-prompt-expand") == []
      assert text_of(d, "#inspector-prompt-expand") =~ "Expand"
      assert present?(d, "#inspector-prompt-edit")
      assert ~w(btn btn-sm btn-ghost) -- classes(d, "#inspector-prompt-edit") == []

      assert d |> LazyHTML.query("#inspector-prompt-edit") |> LazyHTML.attribute("phx-value-mode") == ["edit"]
      assert d |> LazyHTML.query("#inspector-prompt-expand") |> LazyHTML.attribute("phx-value-mode") == ["read"]
      assert d |> LazyHTML.text() |> squish() =~ "RUN PROMPT"
    end

    # Scenario 5
    test "a shell node's inspector labels COMMAND and previews the command as a code block" do
      d = doc(inspector(agent_node(%{type: :shell, run: ~s(bin/ship "{ref}")})))

      assert d |> LazyHTML.text() |> squish() =~ "COMMAND"
      body = inner_html(d, "#inspector-prompt-preview-body")
      assert body =~ ~s(<pre class="prompt-code">)
      assert body =~ ~s(<span class="prompt-placeholder">{ref}</span>)
      refute "md" in classes(d, "#inspector-prompt-preview-body")
      refute body =~ "<p>"
    end

    # Scenario 6
    test "an empty, editable gate node offers a dashed Add a condition… box and no count or Expand" do
      d = doc(inspector(agent_node(%{type: :gate, run: nil})))

      assert text_of(d, "#inspector-prompt-add") == "Add a condition…"
      add = LazyHTML.query(d, "#inspector-prompt-add")
      assert LazyHTML.attribute(add, "phx-click") == ["open_prompt_sheet"]
      assert LazyHTML.attribute(add, "phx-value-mode") == ["edit"]
      assert "border-dashed" in classes(d, "#inspector-prompt-add")
      refute present?(d, "#inspector-prompt-count")
      refute present?(d, "#inspector-prompt-expand")
    end

    # Scenario 7
    test "an empty prompt on a read-only board reads No prompt with no buttons" do
      d = doc(inspector(agent_node(%{run: ""}), read_only?: true))

      assert text_of(d, "#inspector-prompt-empty") == "No prompt"
      refute present?(d, "#inspector-prompt-add")
      refute present?(d, "#inspector-prompt-expand")
      refute present?(d, "#inspector-prompt-edit")
    end

    # Scenario 8
    test "a read-only inspector keeps Expand and drops Edit" do
      d = doc(inspector(agent_node(%{run: @md_prompt}), read_only?: true))

      assert present?(d, "#inspector-prompt-expand")
      refute present?(d, "#inspector-prompt-edit")
    end

    # Scenario 9
    test "the Read sheet is a full-height right-edge drawer with the rendered prompt" do
      d = sheet(agent_node(%{key: "post", run: @md_prompt}), :read)

      assert ~w(drawer drawer-end) -- classes(d, "#prompt-sheet") == []
      root = LazyHTML.query(d, "#prompt-sheet")
      assert LazyHTML.attribute(root, "phx-window-keydown") == ["close_prompt_sheet"]
      assert LazyHTML.attribute(root, "phx-key") == ["escape"]

      panel = classes(d, "#prompt-sheet-panel")

      for c <-
            ~w[drawer-panel flex h-dvh w-full flex-col overflow-hidden bg-base-100 shadow-xl border-l border-base-300] ++
              ["md:w-[min(1180px,90vw)]"] do
        assert c in panel, "expected #{c} on the sheet panel"
      end

      refute Enum.any?(panel, &(String.starts_with?(&1, "rounded") or &1 == "modal-box"))
      assert "drawer-overlay" in classes(d, "#prompt-sheet-overlay")
      assert d |> LazyHTML.query("#prompt-sheet-overlay") |> LazyHTML.attribute("phx-click") == ["close_prompt_sheet"]

      header = d |> LazyHTML.query("#prompt-sheet-panel header") |> LazyHTML.text() |> squish()
      assert header =~ "AGENT"
      assert header =~ "post"
      assert header =~ "RUN PROMPT"
      assert text_of(d, "#prompt-sheet-count") == "17 chars · 2 lines"
      assert ~w(font-mono text-base-content/60) -- classes(d, "#prompt-sheet-count") == []

      assert "btn-active" in classes(d, "#prompt-sheet-mode-read")
      refute "btn-active" in classes(d, "#prompt-sheet-mode-edit")
      assert ~w(join-item btn btn-sm) -- classes(d, "#prompt-sheet-mode-edit") == []
      assert d |> LazyHTML.query("#prompt-sheet-mode-edit") |> LazyHTML.attribute("phx-click") == ["prompt_sheet_mode"]
      assert d |> LazyHTML.query("#prompt-sheet-mode-edit") |> LazyHTML.attribute("phx-value-mode") == ["edit"]

      close = LazyHTML.query(d, "#prompt-sheet-close")
      assert ~w(btn btn-sm btn-ghost btn-circle) -- classes(d, "#prompt-sheet-close") == []
      assert LazyHTML.attribute(close, "aria-label") == ["Close"]
      assert LazyHTML.attribute(close, "title") == ["Close (Esc)"]

      column = LazyHTML.query(d, "#prompt-sheet-read > div")
      assert column |> LazyHTML.attribute("style") |> List.first() =~ "max-width:720px"
      assert "md" in classes(d, "#prompt-sheet-read > div")
      assert LazyHTML.to_html(column) =~ "<li>"

      footer = d |> LazyHTML.query("#prompt-sheet-panel footer") |> LazyHTML.text() |> squish()
      assert footer =~ "Placeholders like {ref} are filled in at run time."
      assert footer =~ "Esc to close"
      assert inner_html(d, "#prompt-sheet-panel footer") =~ ~s(<span class="prompt-placeholder">{ref}</span>)

      refute present?(d, "#prompt-sheet-textarea")
      refute present?(d, "#prompt-sheet-done")
      refute present?(d, "#prompt-sheet-readonly-badge")
    end

    # Scenario 10
    test "the Edit sheet holds the raw text in a textarea that edits through edit_node_field" do
      d = sheet(agent_node(%{key: "post", run: @md_prompt}), :edit)

      form = LazyHTML.query(d, "#prompt-sheet-form[phx-change=edit_node_field]")
      assert Enum.count(form) == 1
      assert present?(d, ~s(#prompt-sheet-form input[type=hidden][name=key][value=post]))
      assert present?(d, ~s(#prompt-sheet-form input[type=hidden][name=field][value=run]))

      textarea = LazyHTML.query(d, "#prompt-sheet-textarea[name=value]")
      assert Enum.count(textarea) == 1
      assert LazyHTML.text(textarea) =~ "- one\n- two {ref}"
      assert "textarea" in classes(d, "#prompt-sheet-textarea")
      assert LazyHTML.attribute(textarea, "spellcheck") == ["false"]

      assert "btn-active" in classes(d, "#prompt-sheet-mode-edit")
      refute "btn-active" in classes(d, "#prompt-sheet-mode-read")
      assert ~w(btn btn-sm btn-primary) -- classes(d, "#prompt-sheet-done") == []
      assert d |> LazyHTML.query("#prompt-sheet-done") |> LazyHTML.attribute("phx-click") == ["close_prompt_sheet"]

      footer = d |> LazyHTML.query("#prompt-sheet-panel footer") |> LazyHTML.text() |> squish()
      assert footer =~ "Markdown."
      assert footer =~ "Save publishes the flow"
      refute present?(d, "#prompt-sheet-read")
    end

    # Scenario 11
    test "a shell node's Edit sheet says nothing about Markdown and reads SHELL / COMMAND" do
      d = sheet(agent_node(%{key: "branch", type: :shell, run: "bin/branch"}), :edit)

      footer = d |> LazyHTML.query("#prompt-sheet-panel footer") |> LazyHTML.text() |> squish()
      refute footer =~ "Markdown."
      header = d |> LazyHTML.query("#prompt-sheet-panel header") |> LazyHTML.text() |> squish()
      assert header =~ "SHELL"
      assert header =~ "COMMAND"
    end

    # Scenario 12
    test "a read-only sheet renders Read with a READ-ONLY badge whatever the mode" do
      d = sheet(agent_node(%{key: "post", run: @md_prompt}), :edit, read_only?: true)

      assert text_of(d, "#prompt-sheet-readonly-badge") == "READ-ONLY"
      assert ~w(badge badge-sm badge-ghost font-mono) -- classes(d, "#prompt-sheet-readonly-badge") == []
      assert present?(d, "#prompt-sheet-read")
      refute present?(d, "#prompt-sheet-mode-read")
      refute present?(d, "#prompt-sheet-mode-edit")
      refute present?(d, "#prompt-sheet-done")
      refute present?(d, "#prompt-sheet-textarea")
    end
  end
end
