defmodule Storybook.Components.CoreComponents.EditableText do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.editable_text/1
  def render_source, do: :function
  def layout, do: :one_column

  def variations do
    [
      %Variation{
        id: :read_filled,
        attributes: %{
          id: "et-read-filled",
          value: "Draft the onboarding spec",
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        }
      },
      %Variation{
        id: :read_empty,
        attributes: %{
          id: "et-read-empty",
          value: "",
          placeholder: "Add a description…",
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        }
      },
      %Variation{
        id: :editing_single_line,
        attributes: %{
          id: "et-edit-single",
          editing: true,
          field: :title,
          form: Phoenix.Component.to_form(%{"title" => "Draft the onboarding spec"}, as: :card),
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        }
      },
      %Variation{
        id: :editing_multiline,
        attributes: %{
          id: "et-edit-multi",
          editing: true,
          multiline: true,
          rows: "6",
          field: :description,
          form: Phoenix.Component.to_form(%{"description" => "Line one\n\nLine two"}, as: :card),
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        }
      }
    ]
  end
end
