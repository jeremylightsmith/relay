defmodule Storybook.Components.CoreComponents.InlineField do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.inline_field/1
  def render_source, do: :function
  def layout, do: :one_column

  def variations do
    [
      %Variation{
        id: :rest_filled,
        attributes: %{
          id: "if-rest-filled",
          value: "Draft the onboarding spec",
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        }
      },
      %Variation{
        id: :rest_blank,
        attributes: %{
          id: "if-rest-blank",
          value: "",
          placeholder: "Untitled",
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        }
      },
      %Variation{
        id: :editing_with_pill,
        attributes: %{
          id: "if-editing",
          editing: true,
          field: :title,
          form: Phoenix.Component.to_form(%{"title" => "Draft the onboarding spec"}, as: :card),
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        },
        template: """
        <div style="padding-bottom:64px"><.psb-variation/></div>
        """
      },
      %Variation{
        id: :editing_with_datalist,
        attributes: %{
          id: "if-editing-datalist",
          editing: true,
          field: :tag,
          form: Phoenix.Component.to_form(%{"tag" => ""}, as: :card),
          datalist: ["design", "infra", "mobile"],
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        },
        template: """
        <div style="padding-bottom:64px"><.psb-variation/></div>
        """
      }
    ]
  end
end
