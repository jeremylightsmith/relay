defmodule Storybook.StagePickerComponents.StagePicker do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias HamacaWeb.StagePickerComponents

  def function, do: &StagePickerComponents.stage_picker/1
  def render_source, do: :function

  # RE502 — card mockup "A — one stage picker; substages nested on indented rows". One picker
  # for the drawer's Move-to, the flow editor's trigger stage and the story map's bulk menus.
  def variations do
    [
      %Variation{
        id: :no_marks,
        description: "The flow editor's trigger stage: owner squares, a nested Review sub-lane, no marks",
        attributes: %{id: "stage-picker-no-marks", heading: "STAGE", event: "pick", rows: stage_rows()}
      },
      %Variation{
        id: :all_mark,
        description: "The drawer's Move-to: the card's current stage carries ✓ and is inert",
        attributes: %{
          id: "stage-picker-all-mark",
          heading: "MOVE TO",
          event: "move_card",
          rows: stage_rows(),
          marks: %{2 => :all},
          filter: "",
          filter_event: "filter_stages",
          pending: true,
          class: "max-h-[260px]"
        }
      },
      %Variation{
        id: :some_mark,
        description: "A bulk move: – where some of the selection already is, ✓ where all of it is",
        attributes: %{
          id: "stage-picker-some-mark",
          heading: "MOVE 3 CARDS TO STAGE",
          event: "bulk_move",
          rows: stage_rows(),
          marks: %{1 => :some, 3 => :some, 4 => :all},
          class: "max-h-[60vh]"
        }
      },
      %Variation{
        id: :filtered,
        description: ~s(Filtering for "rev" flattens the sub-lane to its full name),
        attributes: %{
          id: "stage-picker-filtered",
          heading: "MOVE TO",
          event: "move_card",
          rows: stage_rows(),
          filter: "rev",
          filter_event: "filter_stages"
        }
      },
      %Variation{
        id: :step_headers,
        description: "Story-map steps grouped under their activity's act header",
        attributes: %{
          id: "stage-picker-step-headers",
          heading: "MOVE 3 CARDS TO STEP",
          event: "bulk_move",
          value_name: "step_id",
          rows: step_rows(),
          marks: %{11 => :some}
        }
      }
    ]
  end

  defp stage_rows do
    design = %Schemas.Stage{id: 2, name: "Design", type: :work, parent_id: nil}

    StagePickerComponents.stage_rows(
      [
        %Schemas.Stage{id: 1, name: "Backlog", type: :queue, parent_id: nil},
        design,
        %Schemas.Stage{id: 3, name: "Design:Review", type: :review, parent_id: design.id},
        %Schemas.Stage{id: 4, name: "Code", type: :work, parent_id: nil},
        %Schemas.Stage{id: 5, name: "Done", type: :done, parent_id: nil}
      ],
      MapSet.new([design.id, 4])
    )
  end

  defp step_rows do
    StagePickerComponents.step_rows(
      [
        %Schemas.StoryActivity{id: 1, name: "Capture", position: 0},
        %Schemas.StoryActivity{id: 2, name: "Triage", position: 1}
      ],
      [
        %Schemas.StoryStep{id: 10, name: "Add card", position: 0, story_activity_id: 1},
        %Schemas.StoryStep{id: 11, name: "Voice note", position: 1, story_activity_id: 1},
        %Schemas.StoryStep{id: 20, name: "Sort the inbox", position: 0, story_activity_id: 2}
      ]
    )
  end
end
