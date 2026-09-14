defmodule Storybook.Components.CoreComponents.BlockedStrip do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.blocked_strip/1
  def render_source, do: :function

  defp minutes_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 60, :second)

  def variations do
    [
      # A1 — the agent asked a question and exited; the run is parked on `spec`.
      %Variation{
        id: :question_park,
        attributes: %{
          eyebrow: "SPEC ASKED AND EXITED",
          question: "Should board search cover card bodies and comments, or just titles?",
          blocked_since: minutes_ago(47)
        }
      },
      # A4 — a node failed and the flow routed the card to a human.
      %Variation{
        id: :escalation_park,
        attributes: %{
          eyebrow: "IMPLEMENT FAILED — YOUR CALL",
          question: "✗ commit guard: the working tree is dirty after mix precommit M lib/relay/exports.ex",
          blocked_since: minutes_ago(190)
        }
      },
      # A human set the block by hand — there is no run to name.
      %Variation{
        id: :no_run_block,
        attributes: %{
          eyebrow: "NEEDS YOUR ANSWER",
          question: "Ready to start?",
          blocked_since: minutes_ago(3 * 1440)
        }
      },
      %Variation{
        id: :batch_counter,
        attributes: %{
          eyebrow: "SPEC ASKED AND EXITED",
          question: "Should archived cards match?",
          step: 2,
          step_count: 3,
          blocked_since: minutes_ago(12)
        }
      },
      %Variation{
        id: :loading,
        attributes: %{eyebrow: "SPEC ASKED AND EXITED", loading?: true, blocked_since: minutes_ago(47)}
      },
      %Variation{
        id: :no_blocked_since,
        attributes: %{eyebrow: "NEEDS YOUR ANSWER", question: "Which bucket should exports land in?"}
      }
    ]
  end
end
