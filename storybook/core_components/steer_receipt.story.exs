defmodule Storybook.Components.CoreComponents.SteerReceipt do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.CoreComponents.steer_receipt/1
  def render_source, do: :function

  # RE358 — a steer note's receipt, under its body once a claimed agent job delivered it, and the
  # node's threaded reply once that attempt reports. An undelivered steer (receipt nil) renders
  # nothing — the note's own "sending…" marker covers that state.
  def variations do
    [
      %Variation{
        id: :session_kept,
        description: "Delivered by the restarted attempt, which resumed the stopped one's session.",
        attributes: %{
          id: "steer-receipt-story-kept",
          receipt: %{node: "write_plan", session_kept?: true, reply: nil}
        }
      },
      %Variation{
        id: :noted,
        description: "Delivered without a restart (a steer degraded to a note): no session suffix.",
        attributes: %{
          id: "steer-receipt-story-noted",
          receipt: %{node: "implement", session_kept?: false, reply: nil}
        }
      },
      %Variation{
        id: :with_reply,
        description:
          "The node reported: its outcome detail's first paragraph threads under the receipt, " <>
            "clamped to three lines with a more toggle.",
        attributes: %{
          id: "steer-receipt-story-reply",
          receipt: %{
            node: "write_plan",
            session_kept?: true,
            reply: %{
              detail:
                "Dropped the migration task — the backfill now runs in Task 3, so Task 2 only " <>
                  "adds the column and Task 3 owns the data move end to end.\n\nSecond paragraph.",
              at: DateTime.add(DateTime.utc_now(), -120, :second)
            }
          }
        }
      }
    ]
  end
end
