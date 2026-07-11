defmodule Storybook.Components.CoreComponents.BoxedField do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.boxed_field/1
  def render_source, do: :function
  def layout, do: :one_column

  def variations do
    [
      %Variation{
        id: :form_single_line,
        attributes: %{
          id: "bf-form-single",
          commit: :form,
          field: :name,
          form: Phoenix.Component.to_form(%{"name" => "Acme"}, as: :demo),
          placeholder: "Board name"
        }
      },
      %Variation{
        id: :form_multi_line,
        attributes: %{
          id: "bf-form-multi",
          commit: :form,
          multiline: true,
          rows: "3",
          field: :body,
          form: Phoenix.Component.to_form(%{"body" => ""}, as: :demo),
          placeholder: "Write a comment…"
        }
      },
      %Variation{
        id: :self_markdown_rest,
        attributes: %{
          id: "bf-md-rest",
          markdown: true,
          multiline: true,
          value: "## Heading\n\nRendered **markdown** at rest.",
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        }
      },
      %Variation{
        id: :self_markdown_blank,
        attributes: %{
          id: "bf-md-blank",
          markdown: true,
          multiline: true,
          value: "",
          placeholder: "Add a description…",
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        }
      },
      %Variation{
        id: :self_editing_dirty,
        attributes: %{
          id: "bf-md-edit",
          markdown: true,
          multiline: true,
          editing: true,
          field: :description,
          form: Phoenix.Component.to_form(%{"description" => "raw markdown source"}, as: :card),
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        },
        template: """
        <div style="padding-bottom:72px"><.psb-variation/></div>
        """
      },
      %Variation{
        id: :self_prefixed_slug,
        attributes: %{
          id: "bf-slug",
          field: :slug,
          form: Phoenix.Component.to_form(%{"slug" => "my-board"}, as: :board),
          prefix: "relay.app/",
          save_event: "save",
          cancel_event: "cancel"
        },
        template: """
        <div style="padding-bottom:56px"><.psb-variation/></div>
        """
      }
    ]
  end
end
