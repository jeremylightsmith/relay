defmodule Storybook.RunComponents.HeldWorktreeRow do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.RunComponents.held_worktree_row/1
  def render_source, do: :function

  # One variation per `Relay.Runs.release_action/1` outcome — the row renders precomputed
  # decisions, so these maps mirror what `list_runner_status/2` emits.
  defp holding(overrides) do
    Map.merge(
      %{
        ref: "RE314",
        title: "Archive strands its parked run",
        state: "bound",
        run: %{id: 1, status: :parked, parked_reason: :needs_input},
        since: nil,
        held_s: 2 * 86_400,
        release_requested: false,
        release: :enabled,
        cancellable: true
      },
      overrides
    )
  end

  def variations do
    [
      %Variation{
        id: :bound,
        attributes: %{id: "held-bound", runner: "mac-mini", href: "#", holding: holding(%{})}
      },
      %Variation{
        id: :releasing,
        attributes: %{
          id: "held-releasing",
          runner: "mac-mini",
          href: "#",
          holding: holding(%{release_requested: true, release: :releasing})
        }
      },
      %Variation{
        id: :running,
        attributes: %{
          id: "held-running",
          runner: "mac-mini",
          href: "#",
          holding:
            holding(%{
              ref: "RE330",
              title: "Render needs input as a node badge",
              state: "running",
              run: %{id: 2, status: :running, parked_reason: nil},
              held_s: 540,
              release: {:disabled, "a job is running in this worktree"}
            })
        }
      },
      %Variation{
        id: :talk,
        attributes: %{
          id: "held-talk",
          runner: "mac-mini",
          href: "#",
          holding:
            holding(%{
              ref: "RE301",
              title: "Talk about the board",
              state: "talk",
              run: nil,
              held_s: nil,
              release: {:disabled, "a talk session is attached"},
              cancellable: false
            })
        }
      },
      %Variation{
        id: :retained,
        attributes: %{
          id: "held-retained",
          runner: "mac-mini",
          href: "#",
          holding:
            holding(%{
              ref: "RE299",
              title: "A failed run kept for post-mortem",
              state: "retained",
              run: nil,
              held_s: nil,
              release: :hidden,
              cancellable: false
            })
        }
      }
    ]
  end
end
