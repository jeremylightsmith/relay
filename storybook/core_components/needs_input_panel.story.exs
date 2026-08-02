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
          id_prefix: "sb-question",
          card: card(),
          question: "Should board search cover card bodies and comments, or just titles?",
          answer_form: answer_form()
        }
      },
      %Variation{
        id: :question_stepper,
        attributes: %{
          id_prefix: "sb-stepper",
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
          id_prefix: "sb-escalation",
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
          id_prefix: "sb-escalation-partial",
          card: card(),
          park_kind: :escalation,
          node: "implement",
          attempt: 1,
          question: "implement reported `partial`: 2 of 5 plan tasks were left unimplemented.",
          answer_form: answer_form()
        }
      }
    ]
  end
end
