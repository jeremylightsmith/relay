defmodule Storybook.FlowEditor.PromptPreview do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.FlowEditorComponents.node_inspector/1
  def render_source, do: :function

  # RE459, card mockup "A — rendered preview in inspector, Expand opens a full-height right-edge
  # Read/Edit sheet": the inspector's main-field block — a rendered, clamped preview with its
  # count, Expand and (editable boards only) Edit. The fade shows only when the PromptClamp hook
  # finds the content taller than the clamp, i.e. on the long prompt.
  @long_prompt """
  Post the change for {ref} as a pull request and hand the card back.

  Before you open it:

  - rebase onto `origin/main` and re-run `mix precommit`;
  - read the card with `{relay} card {ref}` and quote its acceptance criteria;
  - link every task the plan checked off.

  Write the PR body in three sections — **What changed**, **Why**, and **How it was verified** —
  and keep each to a few lines. Mention any follow-up card by its ref.

  When the PR is open, comment its URL on the card and declare the outcome with
  `{relay} outcome succeeded`. If CI is red, fix it before you declare anything.
  """

  @short_prompt "Summarise the card for {ref}.\nKeep it to one paragraph."

  def variations do
    [
      %Variation{
        id: :long_agent,
        description: "A long agent prompt — clamped, faded, with {placeholder} chips",
        attributes: inspector(agent_node(%{run: @long_prompt}))
      },
      %Variation{
        id: :short_agent,
        description: "A two-line agent prompt — fits the clamp, so no fade",
        attributes: inspector(agent_node(%{run: @short_prompt}))
      },
      %Variation{
        id: :shell,
        description: "A shell node's COMMAND renders as a code block",
        attributes: inspector(agent_node(%{key: "ship", type: :shell, run: ~s(bin/ship_to_main.sh "{ref}")}))
      },
      %Variation{
        id: :empty,
        description: "No prompt yet — the empty state",
        attributes: inspector(agent_node(%{run: nil}))
      },
      %Variation{
        id: :read_only,
        description: "An archived board — the long prompt with Expand only, no Edit",
        attributes: inspector(agent_node(%{run: @long_prompt}), read_only?: true)
      }
    ]
  end

  # Every key `node_inspector/1` reads (mirrors flow_editor_components_test.exs's agent_node/1).
  defp agent_node(overrides) do
    Map.merge(
      %{
        key: "post",
        type: :agent,
        run: "go",
        agent: nil,
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
    Map.merge(%{node: node, edges: [], referenced_count: 0, board_slug: "demo"}, Map.new(opts))
  end
end
