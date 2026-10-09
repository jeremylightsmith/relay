defmodule Storybook.Components.CoreComponents.FlowChip do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.flow_chip/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :header_enabled,
        description: "RE409 — a stage header's chip: links to the flow editor, bottom tooltip, ↗ on hover",
        attributes: %{id: "story-flow-chip-enabled", flow: %{key: "spec", enabled: true}, board_slug: "acme"}
      },
      %Variation{
        id: :header_disabled,
        description: "The flow is off: grey, dashed, struck-through — still links to the editor",
        attributes: %{id: "story-flow-chip-disabled", flow: %{key: "plan", enabled: false}, board_slug: "acme"}
      },
      %Variation{
        id: :mini,
        description: "The collapsed strip's dot-only chip (tooltip text in title)",
        attributes: %{
          id: "story-flow-chip-mini",
          flow: %{key: "code", enabled: true},
          board_slug: "acme",
          variant: :mini
        }
      },
      %Variation{
        id: :mini_disabled,
        description: "The collapsed strip's dot for a disabled flow — grey",
        attributes: %{
          id: "story-flow-chip-mini-disabled",
          flow: %{key: "code", enabled: false},
          board_slug: "acme",
          variant: :mini
        }
      },
      %Variation{
        id: :pager,
        description: "Phone pager: more padding for touch, no tooltip",
        attributes: %{
          id: "story-flow-chip-pager",
          flow: %{key: "spec", enabled: true},
          board_slug: "acme",
          pager: true
        }
      },
      %Variation{
        id: :read_only,
        description: "Read-only (archived) board: a plain label — no link, no ↗. A disabled flow renders nothing.",
        attributes: %{id: "story-flow-chip-read-only", flow: %{key: "spec", enabled: true}, read_only: true}
      },
      %Variation{
        id: :settings,
        description: "Board settings › Stages: the stage row's AI fact — `<key> flow` linking to the editor",
        attributes: %{
          id: "story-flow-chip-settings",
          flow: %{key: "design", enabled: true},
          board_slug: "acme",
          variant: :settings
        }
      },
      %Variation{
        id: :settings_disabled,
        description: "Board settings › Stages: a disabled flow, no tooltip",
        attributes: %{
          id: "story-flow-chip-settings-disabled",
          flow: %{key: "plan", enabled: false},
          board_slug: "acme",
          variant: :settings
        }
      },
      %Variation{
        id: :header_paused,
        description: "RE432 — paused by a broken board shape: amber, reads \"AI paused\"",
        attributes: %{
          id: "story-flow-chip-paused",
          flow: %{key: "deploy", enabled: true},
          board_slug: "acme",
          paused: true
        }
      },
      %Variation{
        id: :mini_paused,
        description: "RE432 — the collapsed strip's dot for a paused flow — amber",
        attributes: %{
          id: "story-flow-chip-mini-paused",
          flow: %{key: "deploy", enabled: true},
          board_slug: "acme",
          variant: :mini,
          paused: true
        }
      },
      %Variation{
        id: :settings_paused,
        description: "RE432 — Board settings › Stages: a paused flow keeps `<key> flow`, in amber",
        attributes: %{
          id: "story-flow-chip-settings-paused",
          flow: %{key: "deploy", enabled: true},
          board_slug: "acme",
          variant: :settings,
          paused: true
        }
      },
      %Variation{
        id: :read_only_paused,
        description: "RE432 — an archived board's paused flow: a plain amber \"AI paused\" label",
        attributes: %{
          id: "story-flow-chip-read-only-paused",
          flow: %{key: "deploy", enabled: true},
          read_only: true,
          paused: true
        }
      }
    ]
  end
end
