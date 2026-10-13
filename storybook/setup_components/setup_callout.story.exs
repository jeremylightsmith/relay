defmodule Storybook.SetupComponents.SetupCallout do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.SetupComponents.setup_callout/1
  def render_source, do: :function

  # The callout is absolutely positioned by its `.SetupCallout` hook; with no `#board` on the page
  # it sits at its 24px/24px fallback, so each variation gets its own iframe.
  def container, do: {:iframe, style: "height: 260px;"}

  # RE446, card mockup "Payoff — first card turns violet, Settings → Setup, connect a machine",
  # frame A: "An agent has the baton", the callout that points at the first claimed card.
  def variations do
    [
      %Variation{
        id: :planning,
        description: "A · the runner claimed a card in a planning stage",
        attributes: %{
          id: "setup-callout",
          callout: %{card_ref: "STR1", card_id: 1, machine: "jl-mbp", llm: "Claude Code", verb: "planning"}
        }
      },
      %Variation{
        id: :building,
        description: "A card in an in-progress stage, on Codex",
        attributes: %{
          id: "setup-callout",
          callout: %{card_ref: "STR4", card_id: 4, machine: "build-box", llm: "Codex", verb: "building"}
        }
      }
    ]
  end
end
