defmodule Storybook.RunComponents.StarvationBanner do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.RunComponents.starvation_banner/1
  def render_source, do: :function

  # The shape `Relay.Runs.starvation/2` returns.
  def variations do
    [
      %Variation{
        id: :one_holder,
        attributes: %{
          id: "starvation-one",
          verdict: %{
            waiting: [%{job_id: 1, ref: "RE332", node_key: "implement", queued_s: 10_800}],
            holders: [
              %{
                runner: "mac-mini",
                ref: "RE314",
                title: "Archive strands its parked run",
                run_status: :parked,
                parked_reason: :needs_input,
                since: nil,
                held_s: 11 * 86_400
              }
            ]
          }
        }
      },
      %Variation{
        id: :many_holders,
        attributes: %{
          id: "starvation-many",
          verdict: %{
            waiting: [
              %{job_id: 1, ref: "RE332", node_key: "implement", queued_s: 10_800},
              %{job_id: 2, ref: "RE333", node_key: "implement", queued_s: 900}
            ],
            holders: [
              %{
                runner: "mac-mini",
                ref: "RE314",
                title: "Archive strands its parked run",
                run_status: :parked,
                parked_reason: :needs_input,
                since: nil,
                held_s: 11 * 86_400
              },
              %{
                runner: "mac-mini",
                ref: "RE328",
                title: "Runner log improvements",
                run_status: nil,
                parked_reason: nil,
                since: nil,
                held_s: nil
              }
            ]
          }
        }
      }
    ]
  end
end
