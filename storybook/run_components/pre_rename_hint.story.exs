defmodule Storybook.RunComponents.PreRenameHint do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.RunComponents.pre_rename_hint/1
  def render_source, do: :function

  # The Runners-page strip under a runner still installed as `./relay` during the relay → hamaca
  # compatibility window (RE486): neutral, with a copyable `./relay update` and the restart note.
  def variations do
    [
      %Variation{
        id: :default,
        attributes: %{id: "pre-rename-hint"}
      }
    ]
  end
end
