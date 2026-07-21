defmodule Storybook.RunComponents.RunStatusStrip do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.RunComponents.run_status_strip/1
  def render_source, do: :function

  defp detail(attrs) do
    base =
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

    Relay.Runs.run_detail(Map.put(base, :node_executions, []), nil)
  end

  def variations do
    [
      %Variation{
        id: :running,
        attributes: %{detail: detail(%{status: :running}), baton: "BATON · FLOW"}
      },
      %Variation{
        id: :parked,
        attributes: %{detail: detail(%{status: :parked}), baton: "BATON · YOU"}
      },
      %Variation{
        id: :failed,
        attributes: %{
          detail: detail(%{status: :failed, finished_at: DateTime.utc_now()}),
          baton: "BATON · STOPPED"
        }
      },
      %Variation{
        id: :cancelled,
        attributes: %{
          detail: detail(%{status: :cancelled, finished_at: DateTime.utc_now()}),
          baton: "BATON · HUMAN"
        }
      },
      %Variation{
        id: :done,
        attributes: %{
          detail: detail(%{status: :done, current_node: nil, finished_at: DateTime.utc_now()}),
          baton: "BATON · FLOW"
        }
      }
    ]
  end
end
