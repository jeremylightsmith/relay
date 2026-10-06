defmodule Storybook.Components.CoreComponents.Button do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.button/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :default,
        attributes: %{
          type: "button",
          class: "bg-emerald-400 hover:bg-emerald-500 text-emerald-800"
        },
        slots: [
          "Click me!"
        ]
      },
      %Variation{
        id: :disabled,
        attributes: %{
          type: "button",
          disabled: true
        },
        slots: [
          "Click me!"
        ]
      },
      %Variation{
        id: :pending,
        description: "RE394 — pending: idle face; clicking shows the spinner + verb-ing label until the server replies",
        attributes: %{
          type: "button",
          variant: "primary",
          pending: "Approving…"
        },
        slots: [
          "Approve → Spec"
        ]
      },
      %Variation{
        id: :pending_pressed,
        description: "RE394 — the pressed face, forced with a static phx-click-loading class",
        attributes: %{
          type: "button",
          class: "btn btn-primary phx-click-loading",
          pending: "Approving…"
        },
        slots: [
          "Approve → Spec"
        ]
      }
    ]
  end
end
