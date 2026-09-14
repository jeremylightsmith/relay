defmodule Storybook.RunComponents.StoppedWorkBanner do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.RunComponents.stopped_work_banner/1
  def render_source, do: :function

  # The three reasons `Relay.Runs.stopped_work/2` can return, with the sentences
  # `stopped_work_detail/3` actually builds — copy is the verdict's, never the banner's.
  def variations do
    [
      %Variation{
        id: :no_runner,
        attributes: %{
          id: "stopped-work-no-runner",
          verdict: %{
            reason: :no_runner,
            detail: "No jobs claimed in 3m · no runner is connected to run this board's work."
          }
        }
      },
      %Variation{
        id: :runner_gone,
        attributes: %{
          id: "stopped-work-runner-gone",
          verdict: %{
            reason: :runner_gone,
            detail: "No jobs claimed in 12m · no runner is connected to run this board's work."
          }
        }
      },
      %Variation{
        id: :runner_outdated,
        attributes: %{
          id: "stopped-work-runner-outdated",
          verdict: %{
            reason: :runner_outdated,
            detail:
              "No jobs claimed in 7m · every connected runner is running old code and is being " <>
                "refused — running v0/unversioned, requires v#{Relay.Runs.min_runner_version()}. " <>
                "Restart it to pick up current code."
          }
        }
      }
    ]
  end
end
