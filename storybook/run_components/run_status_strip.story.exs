defmodule Storybook.RunComponents.RunStatusStrip do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.RunComponents.run_status_strip/1
  def render_source, do: :function

  defp run(attrs) do
    Map.merge(
      %{
        status: :running,
        flow_key: "code",
        flow_version: 3,
        current_node: "implement",
        started_at: DateTime.add(DateTime.utc_now(), -291, :second),
        finished_at: nil
      },
      attrs
    )
  end

  def variations do
    [
      %Variation{
        id: :running,
        attributes: %{run: run(%{status: :running}), baton: "BATON · FLOW"}
      },
      %Variation{
        id: :parked,
        attributes: %{run: run(%{status: :parked}), baton: "BATON · YOU"}
      },
      %Variation{
        id: :failed,
        attributes: %{
          run: run(%{status: :failed, finished_at: DateTime.utc_now()}),
          baton: "BATON · STOPPED"
        }
      },
      %Variation{
        id: :cancelled,
        attributes: %{
          run: run(%{status: :cancelled, finished_at: DateTime.utc_now()}),
          baton: "BATON · HUMAN"
        }
      },
      %Variation{
        id: :done,
        attributes: %{
          run: run(%{status: :done, current_node: nil, finished_at: DateTime.utc_now()}),
          baton: "BATON · FLOW"
        }
      }
    ]
  end
end
