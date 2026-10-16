defmodule Storybook.TemplatePickerComponents.TemplatePicker do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.TemplatePickerComponents.template_picker/1
  def render_source, do: :function

  # The picker overlays its whole viewport (a fixed scrim + panel), so each variation renders
  # inside its own iframe.
  def container, do: {:iframe, style: "height: 820px;"}

  @relay_agents ~w(plan-implementer spec-reviewer quality-reviewer final-fixer rebaser smoke-tester acceptance-tester final-reviewer ci-fixer)

  # RE442, card mockup "Picker — New board opens three template cards": the real templates from
  # `Relay.Boards.templates/0`, once per selection (the warning box shows on the third).
  def variations do
    templates = Relay.Boards.templates()

    selections =
      for {variation_id, template} <- Enum.zip([:first_selected, :second_selected, :third_selected], templates) do
        %Variation{
          id: variation_id,
          description: "#{template.name} selected",
          attributes: %{templates: templates, selected: template.slug}
        }
      end

    # RE444: with the example boards seeded, every card links to its public example.
    selections ++
      [
        %Variation{
          id: :with_examples,
          description: "Examples seeded — each card links to its public example",
          attributes: %{
            templates: templates,
            selected: hd(templates).slug,
            examples: %{
              "bare-minimum" => "Streaks (bare-minimum)",
              "design-led" => "Pantry (design-led)",
              "three-brain" => "Tiny Dungeon (three-brain)"
            }
          }
        },
        # RE447, card mockup "Picker — 4th option: copy from a board I have access to".
        %Variation{
          id: :copy_selected,
          description: "Copy selected — Relay chosen, its flows name 9 repo files",
          attributes: %{
            templates: templates,
            selected: RelayWeb.TemplatePickerComponents.copy_option(),
            copy_from: "relay",
            copy_sources: [
              %{slug: "relay", name: "Relay", key: "RE", stages: 9, flows: 4, files: agent_files(@relay_agents)},
              %{slug: "acme-web", name: "Acme web", key: "ACM", stages: 7, flows: 3, files: []}
            ]
          }
        },
        %Variation{
          id: :copy_many_boards,
          description:
            "Copy selected with 40 boards — the list scrolls in place; the warning and button stay right under it",
          attributes: %{
            templates: templates,
            selected: RelayWeb.TemplatePickerComponents.copy_option(),
            copy_from: "relay",
            copy_sources: [
              %{slug: "relay", name: "Relay", key: "RE", stages: 9, flows: 4, files: agent_files(@relay_agents)}
              | for(
                  i <- 1..39,
                  do: %{slug: "board-#{i}", name: "Board #{i}", key: "B#{i}", stages: 7, flows: 3, files: []}
                )
            ]
          }
        },
        %Variation{
          id: :copy_no_boards,
          description: "Copy selected with no boards to copy — the button is disabled",
          attributes: %{
            templates: templates,
            selected: RelayWeb.TemplatePickerComponents.copy_option(),
            copy_sources: []
          }
        },
        # RE455, card mockup "A — name + card key, required, at the top of the New board picker".
        %Variation{
          id: :identity_empty,
          description: "Just opened — name and key empty, Create disabled",
          attributes: %{templates: templates, selected: "design-led", name: "", key: ""}
        },
        %Variation{
          id: :identity_filled,
          description: "Name and key filled — the key previews its refs, Create names the board",
          attributes: %{templates: templates, selected: "design-led", name: "Acme Checkout", key: "AC"}
        },
        %Variation{
          id: :identity_incomplete,
          description: "One-letter key — Needs 2 letters, Create disabled",
          attributes: %{templates: templates, selected: "design-led", name: "Acme Checkout", key: "A"}
        },
        %Variation{
          id: :copy_identity_required,
          description: "Copy selected after interacting — name and key still required, never pre-filled",
          attributes: %{
            templates: templates,
            selected: RelayWeb.TemplatePickerComponents.copy_option(),
            copy_from: "relay",
            copy_sources: [%{slug: "relay", name: "Relay", key: "RE", stages: 9, flows: 14, files: []}],
            name: "",
            key: "",
            show_required: true
          }
        }
      ]
  end

  defp agent_files(names) do
    for name <- names do
      %{kind: :agent, name: name, paths: [".claude/agents/#{name}.md"], used_by: [%{flow: "code", node: name}]}
    end
  end
end
