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
        id: :self_editing_savecancel,
        attributes: %{
          id: "bf-md-edit",
          markdown: true,
          multiline: true,
          editing: true,
          label: "Spec",
          accent: :primary,
          field: :spec,
          form: Phoenix.Component.to_form(%{"spec" => "## Goal\n\nraw markdown source"}, as: :card),
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        }
      },
      %Variation{
        id: :self_collapsed_preview,
        attributes: %{
          id: "bf-spec-collapsed",
          markdown: true,
          multiline: true,
          collapsible: true,
          expanded: false,
          label: "Spec",
          accent: :primary,
          toggle_event: "toggle_spec",
          value:
            "## Goal\n\nShip the Safari checkout fix. Reproduces on iOS 17 when the network is slow; the payment sheet double-fires.\n\n- Add a regression test\n- Idempotency key on submit",
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        }
      },
      %Variation{
        id: :self_expanded_read,
        attributes: %{
          id: "bf-plan-expanded",
          markdown: true,
          multiline: true,
          collapsible: true,
          expanded: true,
          label: "Plan",
          accent: :secondary,
          toggle_event: "toggle_plan",
          value: "## Task 1\n\n- [x] migration\n- [ ] wire the API\n\n## Task 2\n\n- [ ] drawer",
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        }
      },
      %Variation{
        id: :self_empty_add,
        attributes: %{
          id: "bf-spec-empty",
          markdown: true,
          multiline: true,
          collapsible: true,
          label: "Spec",
          accent: :primary,
          toggle_event: "toggle_spec",
          value: "",
          placeholder: "Add a spec…",
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        }
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
