defmodule Storybook.Components.CoreComponents.PlanTasks do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  import Phoenix.Component, only: [to_form: 2]

  def function, do: &HamacaWeb.CoreComponents.plan_tasks/1
  def render_source, do: :function

  # Built rather than typed so no literal triple-backtick appears in this source.
  @fence String.duplicate("`", 3)

  @plan "Split the drawer's flat checklist into expandable task rows. Header here, tasks below."

  @long_body Enum.map_join(1..22, "\n", &"- Step #{&1}: move one piece of the checklist into its row.") <>
               "\n\n#{@fence}elixir\ndef up do\n  alter table(:sub_tasks) do\n    add :body, :text\n  end\nend\n#{@fence}\n"

  defp tasks do
    [
      %{
        id: 1,
        title: "Add the body column",
        done: true,
        body: "Migration plus schema field.\n\n#{@fence}elixir\nadd :body, :text\n#{@fence}\n"
      },
      %{id: 2, title: "Render tasks as an accordion", done: false, body: @long_body},
      %{
        id: 3,
        title: "Auto-open the in-flight task",
        done: false,
        body: "Follow the **baton**: the task the agent is on opens by itself."
      },
      %{id: 4, title: "Add the storybook story", done: false, body: nil}
    ]
  end

  defp base(id, extra) do
    Map.merge(%{id: id, plan: @plan, tasks: tasks(), progress: %{done: 1, total: 4}}, extra)
  end

  def variations do
    [
      %Variation{id: :collapsed, attributes: base("story-plan-collapsed", %{})},
      %Variation{
        id: :in_flight_open,
        attributes: base("story-plan-in-flight", %{in_flight_task_id: 3, open_task_id: 3})
      },
      %Variation{
        id: :long_body_clamped,
        attributes: base("story-plan-clamped", %{in_flight_task_id: 2, open_task_id: 2})
      },
      %Variation{
        id: :clamp_released,
        attributes: base("story-plan-released", %{open_task_id: 2, task_full?: true})
      },
      %Variation{id: :done_task, attributes: base("story-plan-done", %{open_task_id: 1})},
      %Variation{
        id: :body_less,
        attributes:
          base("story-plan-body-less", %{
            tasks: [%{id: 4, title: "Add the storybook story", done: false, body: nil}],
            progress: %{done: 0, total: 1}
          })
      },
      # RE507 — card mockup "Edit inline, in the row — ⋯ always visible".
      %Variation{id: :at_rest, attributes: base("story-plan-at-rest", %{})},
      %Variation{id: :menu_open, attributes: base("story-plan-menu-open", %{task_menu_id: 3})},
      %Variation{
        id: :delete_confirm,
        attributes: base("story-plan-delete-confirm", %{confirm_delete_task_id: 2})
      },
      %Variation{
        id: :editing,
        attributes:
          base("story-plan-editing", %{
            editing_task_id: 3,
            task_form:
              to_form(
                %{
                  "title" => "Auto-open the in-flight task",
                  "body" => "Follow the **baton**: the task the agent is on opens by itself."
                },
                as: :task
              )
          })
      },
      %Variation{
        id: :adding,
        attributes: base("story-plan-adding", %{adding_task: true, add_form: to_form(%{"title" => ""}, as: :task)})
      },
      %Variation{
        id: :locked,
        attributes: base("story-plan-locked", %{locked: true, in_flight_task_id: 3, open_task_id: 3})
      },
      %Variation{
        id: :empty,
        description: "No plan and no tasks — + Add task still works the list as a plain checklist",
        attributes: %{id: "story-plan-empty", plan: nil, tasks: [], progress: %{done: 0, total: 0}}
      }
    ]
  end
end
