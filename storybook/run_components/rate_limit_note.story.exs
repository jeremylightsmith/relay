defmodule Storybook.RunComponents.RateLimitNote do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.RunComponents.rate_limit_note/1
  def render_source, do: :function

  # The Runners-page line for a runner paused at its usage limits — every installed harness paused
  # (RE320, per harness since RE436). The map is `Relay.Runs.active_rate_limit/2`'s: the harness
  # pause that lifts first.
  def variations do
    [
      %Variation{
        id: :limit,
        attributes: %{
          id: "rate-limit-note-limit",
          rate_limit: %{
            harness: "codex",
            window: "5h",
            used_pct: 92.0,
            pause_at: 90,
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
            harness: "claude-code",
            window: nil,
            used_pct: nil,
            pause_at: nil,
            reason: "rejected",
            resets_at: ~U[2026-09-16 09:00:00Z]
          }
        }
      }
    ]
  end
end
