defmodule Storybook.ValueStream.StatTile do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.ValueStreamComponents.stat_tile/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :plain,
        attributes: %{id: "tile-lead", label: "CARD LEAD TIME", value: "1.8d", sub: "Next up → Done"}
      },
      %Variation{
        id: :hot,
        attributes: %{
          id: "tile-eff",
          label: "FLOW EFFICIENCY",
          value: "2.1%",
          sub: "value-add ÷ card lead time",
          tone: :error,
          hot: true
        }
      },
      %Variation{
        id: :agent,
        attributes: %{id: "tile-agent", label: "BATON: AGENT", value: "3%", sub: "1.5h across 3 flows", tone: :secondary}
      }
    ]
  end
end
