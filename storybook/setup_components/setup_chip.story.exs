defmodule Storybook.SetupComponents.SetupChip do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  # The setup chip in ⋯ → Setup. RE505, card mockup "B — existing controls: panel ⟨ hides for
  # everyone; ⋯ Setup or Settings → Reopen brings it back", frame 2: a shown setup keeps the
  # primary tint, a hidden one goes grey (`badge-ghost`).

  def function, do: &HamacaWeb.SetupComponents.setup_chip/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :unfinished,
        description: "Shown, on step 3",
        attributes: %{id: "setup-chip", checklist: %{finished?: false, closed?: false, position: 3, total: 7}}
      },
      %Variation{
        id: :hidden,
        description: "Hidden for everyone, stopped on step 3",
        attributes: %{id: "setup-chip", checklist: %{finished?: false, closed?: true, position: 3, total: 7}}
      },
      %Variation{
        id: :done,
        description: "Finished",
        attributes: %{id: "setup-chip", checklist: %{finished?: true, closed?: false, position: 7, total: 7}}
      }
    ]
  end
end
