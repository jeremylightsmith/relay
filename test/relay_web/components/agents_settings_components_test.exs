defmodule RelayWeb.AgentsSettingsComponentsTest do
  @moduledoc "RE433 — the Settings → Agents pieces' mockup values (card mockup 01)."
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RelayWeb.AgentsSettingsComponents
  alias Schemas.Agent
  alias Schemas.Harness

  @gemini %Harness{
    id: 3,
    key: "gemini-cli",
    name: "Gemini CLI",
    command: "gemini -p {prompt} --model {model}",
    models: ["gemini-2.5-flash"]
  }

  @opus_harness %Harness{id: 1, key: "claude-code", name: "Claude Code", command: "claude -p {prompt}", models: ["opus"]}

  defp q(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp attr(html, selector, name), do: html |> q(selector) |> LazyHTML.attribute(name) |> List.first()

  defp table_html do
    agents = [
      %Agent{id: 10, name: "Claude Opus", model: "opus", harness_id: 1, harness: @opus_harness},
      %Agent{id: 11, name: "Gemini Pro", model: "gemini-2.5-pro", harness_id: 3, harness: @gemini}
    ]

    render_component(&AgentsSettingsComponents.agents_table/1, agents: agents, default_agent_id: 10, usage: %{})
  end

  describe "12. agents_table/1" do
    test "a red row carries the error inset and tint" do
      style = attr(table_html(), "#agent-row-11", "style")

      assert attr(table_html(), "#agent-row-11", "data-red") == "true"
      assert style =~ "inset 3px 0 0 var(--color-error)"
      assert style =~ "color-mix(in oklab, var(--color-error) 8%, var(--color-base-100))"
      assert is_nil(attr(table_html(), "#agent-row-10", "data-red"))
    end

    test "the MODEL REMOVED badge is the soft error badge" do
      classes = attr(table_html(), "#agent-row-11-removed", "class")
      assert classes =~ "badge badge-sm badge-error badge-soft font-mono"
    end

    test "the DEFAULT badge is the soft secondary badge" do
      classes = attr(table_html(), "#agent-row-10-default", "class")
      assert classes =~ "badge-secondary badge-soft"
      assert classes =~ "badge badge-sm"
    end
  end

  describe "12. harness_form/1" do
    test "Advanced is a closed <details> and the hint lists every placeholder chip" do
      form = @gemini |> Relay.Agents.change_harness() |> Phoenix.Component.to_form()
      html = render_component(&AgentsSettingsComponents.harness_form/1, form: form, harness: @gemini, agent_count: 0)

      advanced = q(html, "details#harness-form-advanced")
      assert Enum.count(advanced) == 1
      assert is_nil(advanced |> LazyHTML.attribute("open") |> List.first())

      chips = html |> q("[data-placeholder-chip]") |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
      assert chips == Enum.map(Harness.placeholders(), &"{#{&1}}")
      assert length(chips) == 7
    end
  end
end
