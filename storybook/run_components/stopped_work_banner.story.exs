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
        id: :no_executor,
        attributes: %{
          id: "stopped-work-no-executor",
          verdict: %{
            reason: :no_executor,
            detail: "No jobs claimed in 3m · no executor is connected to run this board's work."
          }
        }
      },
      %Variation{
        id: :executor_gone,
        attributes: %{
          id: "stopped-work-executor-gone",
          verdict: %{
            reason: :executor_gone,
            detail: "No jobs claimed in 12m · no executor is connected to run this board's work."
          }
        }
      },
      %Variation{
        id: :executor_outdated,
        attributes: %{
          id: "stopped-work-executor-outdated",
          verdict: %{
            reason: :executor_outdated,
            detail:
              "No jobs claimed in 7m · every connected executor is running old code and is being " <>
                "refused — running v0/unversioned, requires v#{Relay.Runs.min_executor_version()}. " <>
                "Restart it to pick up current code."
          }
        }
      }
    ]
  end
end
