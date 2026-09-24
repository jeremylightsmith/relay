defmodule Storybook.CoreComponents.NeedsInputPanel do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.needs_input_panel/1
  def render_source, do: :function

  defp card, do: %{blocked_since: DateTime.add(DateTime.utc_now(), -720, :second)}
  defp answer_form, do: Phoenix.Component.to_form(%{"body" => ""}, as: :answer)

  @guard """
  ✗ commit guard: the working tree is dirty after `mix precommit`

    M lib/relay/exports.ex
    M test/relay/exports_test.exs

  mix format rewrote two files the implementer already committed, so the node
  ends with uncommitted changes and cannot hand the branch on.
  """

  def variations do
    [
      %Variation{
        id: :question,
        attributes: %{
          card: card(),
          question: "Should board search cover card bodies and comments, or just titles?",
          answer_form: answer_form()
        }
      },
      %Variation{
        id: :question_stepper,
        attributes: %{
          card: card(),
          answer_form: answer_form(),
          answer_step: 0,
          answer_values: %{},
          answer_questions: [
            %{
              "prompt" => "Should board search cover card bodies and comments, or just titles?",
              "options" => ["Full-text: bodies + comments", "Titles only for now"],
              "allow_text" => true
            },
            %{"prompt" => "Should archived cards match?", "options" => ["Yes", "No"], "allow_text" => false}
          ]
        }
      },
      # RE253 — a `--on failed --> needs_input` edge escalated a node failure to a human.
      %Variation{
        id: :escalation,
        attributes: %{
          card: card(),
          park_kind: :escalation,
          node: "implement",
          attempt: 3,
          question: @guard,
          failure_detail: @guard,
          answer_form: answer_form()
        }
      },
      # RE253 — an A9 (`:partial`) escalation. `last_failure_detail/1` keeps `:failed` executions
      # only, so there is no dark <pre> here and the question carries the failure text instead.
      %Variation{
        id: :escalation_without_failure_detail,
        attributes: %{
          card: card(),
          park_kind: :escalation,
          node: "implement",
          attempt: 1,
          question: "implement reported `partial`: 2 of 5 plan tasks were left unimplemented.",
          answer_form: answer_form()
        }
      },
      # RE279/RE310 — a parked run whose bound foreach task is already committed: the advance
      # control now sits at the foot of this panel, after the answer controls.
      %Variation{
        id: :escalation_with_advance,
        attributes: %{
          card: card(),
          park_kind: :escalation,
          node: "implement",
          attempt: 2,
          failure_detail: "already committed: nothing to do for task 3",
          answer_form: answer_form(),
          advance_available?: true
        }
      },
      # RE308 (A11) — the node's agent could not run at all (an expired login). Retry only: no
      # answer box, no attempt count.
      %Variation{
        id: :infrastructure,
        attributes: %{
          card: card(),
          park_kind: :infrastructure,
          node: "quality_review",
          question: "agent could not run: Failed to authenticate: OAuth session expired and could not be refreshed",
          failure_detail: "agent could not run: Failed to authenticate: OAuth session expired and could not be refreshed",
          answer_form: answer_form()
        }
      }
    ]
  end
end
