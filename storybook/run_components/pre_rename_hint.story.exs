defmodule Storybook.RunComponents.PreRenameHint do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.RunComponents.pre_rename_hint/1
  def render_source, do: :function

  # The Runners-page amber strip under a runner refused because it is still installed as `./relay`
  # (RE486, RE482): "Refused:", a copyable install one-liner (`Hamaca.Setup.install_command/2`) and
  # the `./hamaca start` restart note.
  def variations do
    [
      %Variation{
        id: :default,
        attributes: %{
          id: "pre-rename-hint",
          command: "curl -fsSL https://hamaca.example/b/my-board/install | sh"
        }
      }
    ]
  end
end
