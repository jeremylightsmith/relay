defmodule Storybook.RunComponents.RateLimitNote do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.RunComponents.rate_limit_note/1
  def render_source, do: :function

  # The Runners-page line for a runner paused at its Claude usage limit (RE320).
  def variations do
    [
      %Variation{
        id: :limit,
        attributes: %{
          id: "rate-limit-note-limit",
          rate_limit: %{
            window: "five_hour",
            utilization: 0.92,
            max: 0.9,
            reason: "limit",
            resets_at: ~U[2026-09-14 15:40:00Z]
          }
        }
      },
      %Variation{
        id: :rejected,
        attributes: %{
          id: "rate-limit-note-rejected",
          rate_limit: %{
            window: "seven_day",
            utilization: nil,
            max: nil,
            reason: "rejected",
            resets_at: ~U[2026-09-16 09:00:00Z]
          }
        }
      }
    ]
  end
end
