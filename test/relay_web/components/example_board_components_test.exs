defmodule RelayWeb.ExampleBoardComponentsTest do
  @moduledoc """
  RE444: the read-only building blocks of a public example board — banner, badges, intro, WIP
  explainer, one flow section with its node panel, and the card detail modal.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RelayWeb.ExampleBoardComponents

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp q(doc, selector), do: LazyHTML.query(doc, selector)
  defp text(doc, selector), do: doc |> q(selector) |> LazyHTML.text() |> String.trim()
  defp count(doc, selector), do: doc |> q(selector) |> Enum.count()

  describe "example_banner/1" do
    test "says it is a public example and links to the template" do
      doc =
        (&ExampleBoardComponents.example_banner/1)
        |> render_component(
          template_name: "Bare minimum",
          slug: "bare-minimum",
          use_href: "/boards?template=bare-minimum"
        )
        |> doc()

      banner_text = text(doc, "#example-banner #example-banner-text")
      assert banner_text =~ "This is a public example of the Bare minimum template."
      assert banner_text =~ "Nothing here can be moved or edited."

      link = q(doc, "a#use-template")
      assert LazyHTML.attribute(link, "href") == ["/boards?template=bare-minimum"]
      assert link |> LazyHTML.text() |> String.trim() == "Use the bare-minimum template"
    end
  end

  describe "example_badges/1" do
    test "renders the public and read-only badges" do
      doc = (&ExampleBoardComponents.example_badges/1) |> render_component(%{}) |> doc()

      assert text(doc, "#example-badge-public") == "public"
      assert text(doc, "#example-badge-read-only") == "read-only"
    end
  end

  describe "example_intro/1" do
    test "renders the name, pitch, both baton lines and the facts" do
      example = %{
        name: "Streaks (bare-minimum)",
        pitch: "A habit tracker.",
        baton: %{ai: "AI builds", human: "You review"},
        facts: "4 stages · 1 flow"
      }

      doc = (&ExampleBoardComponents.example_intro/1) |> render_component(example: example) |> doc()

      assert text(doc, "#example-intro h1#example-title") == "Streaks (bare-minimum)"
      assert text(doc, "#example-pitch") == "A habit tracker."
      assert text(doc, "#example-baton-ai") =~ "AI builds"
      assert text(doc, "#example-baton-human") =~ "You review"
      assert text(doc, "#example-facts") == "4 stages · 1 flow"
    end
  end

  describe "wip_explainer/1" do
    test "renders the title, the chip and the How / Why / Here rows" do
      doc =
        (&ExampleBoardComponents.wip_explainer/1)
        |> render_component(
          chip: "wip 2/2",
          wip: %{how: "H", why: "W", here: "X"}
        )
        |> doc()

      explainer = text(doc, "#wip-explainer")
      assert explainer =~ "WIP limits on this board"
      assert explainer =~ "wip 2/2"

      for {id, label, body} <- [{"#wip-how", "How", "H"}, {"#wip-why", "Why", "W"}, {"#wip-here", "Here", "X"}] do
        row = text(doc, id)
        assert row =~ label
        assert row =~ body
      end
    end
  end

  describe "node_panel/1" do
    test "an inline agent node shows its model, the inline tag and the whole prompt" do
      doc =
        (&ExampleBoardComponents.node_panel/1)
        |> render_component(
          flow_key: "three-brain-plan",
          node: %{key: "gpt_plan", type: :agent, agent: nil, run: "line one\n\nline two", llm: "GPT"},
          agent: %{name: "GPT", harness: "Codex"}
        )
        |> doc()

      panel = text(doc, "aside#node-panel-three-brain-plan[data-node=gpt_plan]")
      assert panel =~ "AGENT"
      assert panel =~ "gpt_plan"

      assert text(doc, "#node-panel-three-brain-plan-llm") == "Codex · GPT"
      assert text(doc, "#node-panel-three-brain-plan-inline") == "inline · no skill"

      prompt = doc |> q("#node-panel-three-brain-plan-prompt") |> LazyHTML.text()
      # Untrimmed on purpose: the box is `white-space:pre-wrap`, so any whitespace around the
      # interpolation would render as a leading blank line and indent.
      assert prompt == "line one\n\nline two"
    end

    test "a shell node shows its command but no model chip or inline tag" do
      doc =
        (&ExampleBoardComponents.node_panel/1)
        |> render_component(
          flow_key: "implement",
          node: %{key: "validate", type: :shell, run: "npm test", agent: nil},
          agent: nil
        )
        |> doc()

      panel = text(doc, "#node-panel-implement")
      assert panel =~ "SHELL"
      assert text(doc, "#node-panel-implement-prompt") == "npm test"
      assert count(doc, "#node-panel-implement-llm") == 0
      assert count(doc, "#node-panel-implement-inline") == 0
    end

    test "a control node shows only its tag and key" do
      doc =
        (&ExampleBoardComponents.node_panel/1)
        |> render_component(
          flow_key: "implement",
          node: %{key: "split", type: :fan_out, run: nil},
          agent: nil
        )
        |> doc()

      panel = text(doc, "#node-panel-implement[data-node=split]")
      assert panel =~ "FAN OUT"
      assert panel =~ "split"
      assert count(doc, "#node-panel-implement-prompt") == 0
    end
  end

  describe "example_flow/1" do
    @plan_flow %{
      key: "plan",
      nodes: [%{key: "plan", type: :agent, agent: nil, run: "Write the plan.", llm: nil, effort: nil}],
      edges: [%{from: "start", to: "plan", on: nil}, %{from: "plan", to: "done", on: :succeeded}],
      pulls_from_stage: %{name: "Backlog"},
      stage: %{name: "Plan"},
      lands_on_stage: %{name: "Implement"}
    }

    defp flow_section(attrs) do
      (&ExampleBoardComponents.example_flow/1)
      |> render_component(
        Map.merge(
          %{
            flow: @plan_flow,
            blurb: nil,
            selected: "plan",
            llm: %{default: "Claude Opus", red: MapSet.new()},
            agents: %{"Claude Opus" => %{name: "Claude Opus", harness: "Claude Code"}}
          },
          attrs
        )
      )
      |> doc()
    end

    test "renders the header, neighbour badges, its own graph and the selected node's panel" do
      doc = flow_section(%{})

      assert count(doc, "section#example-flow-plan") == 1
      assert text(doc, "#example-flow-plan-meta") == "1 node"

      header = text(doc, "#example-flow-plan")
      assert header =~ ~r/PULLS FROM\s+Backlog/
      assert header =~ ~r/WORKS IN\s+Plan/
      assert header =~ ~r/LANDS ON SUCCESS\s+Implement/

      assert count(doc, "#flow-graph-plan") == 1
      assert count(doc, "#node-panel-plan[data-node=plan]") == 1
      assert text(doc, "#node-panel-plan-llm") == "Claude Code · Claude Opus"
    end

    test "a blurb follows the node count" do
      assert %{blurb: "design before"} |> flow_section() |> text("#example-flow-plan-meta") == "1 node · design before"
    end

    test "a nil neighbour omits its badge" do
      doc = flow_section(%{flow: %{@plan_flow | pulls_from_stage: nil}})

      refute text(doc, "#example-flow-plan") =~ "PULLS FROM"
      assert text(doc, "#example-flow-plan") =~ "WORKS IN"
    end
  end

  describe "example_card_detail/1" do
    @card %{title: "Monthly calendar view", ref: "ST11", status: :needs_input, description: "Show a **month**."}
    @tasks [%{title: "A", done: true}, %{title: "B", done: false}]

    defp card_detail(question) do
      render_component(&ExampleBoardComponents.example_card_detail/1, card: @card, tasks: @tasks, question: question)
    end

    test "renders the card read-only, with its status, markdown, tasks and question" do
      html = card_detail("Sunday or Monday?")
      doc = doc(html)

      assert count(doc, "#example-card-modal.modal.modal-open") == 1
      assert text(doc, "#example-card-modal") =~ "Monthly calendar view"
      assert text(doc, "#example-card-modal") =~ "ST11"
      assert text(doc, "#example-card-status") == "needs input"
      assert doc |> q("#example-card-description") |> LazyHTML.to_html() =~ "<strong>month</strong>"

      tasks = q(doc, "#example-card-tasks li")
      assert Enum.count(tasks) == 2
      assert tasks |> Enum.at(0) |> LazyHTML.attribute("data-done") == ["true"]
      assert tasks |> Enum.at(1) |> LazyHTML.attribute("data-done") == ["false"]

      assert text(doc, "#example-card-question") =~ "Sunday or Monday?"

      assert doc |> q("button") |> Enum.map(&LazyHTML.attribute(&1, "id")) == [["example-card-close"]]
      assert count(doc, "form") == 0
    end

    test "only close_card events are wired" do
      doc = doc(card_detail("Sunday or Monday?"))

      assert LazyHTML.attribute(q(doc, "#example-card-close"), "phx-click") == ["close_card"]

      events = doc |> q("[phx-click]") |> LazyHTML.attribute("phx-click") |> Enum.uniq()
      assert events == ["close_card"]
      refute card_detail("Sunday or Monday?") =~ ~r/phx-(change|submit|keydown|blur|focus)/
    end

    test "no question renders no question box" do
      assert nil |> card_detail() |> doc() |> count("#example-card-question") == 0
    end
  end
end
