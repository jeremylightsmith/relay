defmodule Storybook.TemplatePickerComponents.TemplatePicker do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.TemplatePickerComponents.template_picker/1
  def render_source, do: :function

  # The picker overlays its whole viewport (a fixed scrim + panel), so each variation renders
  # inside its own iframe.
  def container, do: {:iframe, style: "height: 820px;"}

  # RE442, card mockup "Picker — New board opens three template cards": the real templates from
  # `Relay.Boards.templates/0`, once per selection (the warning box shows on the third).
  def variations do
    templates = Relay.Boards.templates()

    for {variation_id, template} <- Enum.zip([:first_selected, :second_selected, :third_selected], templates) do
      %Variation{
        id: variation_id,
        description: "#{template.name} selected",
        attributes: %{templates: templates, selected: template.slug}
      }
    end
  end
end
