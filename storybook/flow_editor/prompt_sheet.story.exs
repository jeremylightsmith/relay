defmodule Storybook.FlowEditor.PromptSheet do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.FlowEditorComponents.prompt_sheet/1
  def render_source, do: :function

  # The sheet is page-fixed (a full-height, right-edge drawer over a scrim), so each variation
  # renders inside its own iframe.
  def container, do: {:iframe, style: "height: 820px;"}

  # RE459, card mockup "A — rendered preview in inspector, Expand opens a full-height right-edge
  # Read/Edit sheet": states "Expanded · reading", "Expanded · editing", "Read-only · expanded".
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

  @agent %{key: "post", type: :agent, run: @long_prompt}
  @shell %{key: "ship", type: :shell, run: ~s(bin/ship_to_main.sh "{ref}")}

  def variations do
    [
      %Variation{
        id: :read,
        description: "Reading an agent's RUN PROMPT, rendered as markdown with {placeholder} chips",
        attributes: %{node: @agent, mode: :read}
      },
      %Variation{
        id: :edit,
        description: "Editing the raw prompt; edits post edit_node_field",
        attributes: %{node: @agent, mode: :edit}
      },
      %Variation{
        id: :read_only,
        description: "An archived board — forced to Read, READ-ONLY badge, no Edit path",
        attributes: %{node: @agent, mode: :read, read_only?: true}
      },
      %Variation{
        id: :shell,
        description: "A shell node's COMMAND, read as a code block",
        attributes: %{node: @shell, mode: :read}
      }
    ]
  end
end
