defmodule Storybook.AdminComponents.StackedBars do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.AdminComponents.stacked_bars/1
  def render_source, do: :function

  # RE475, card mockup "Usage tab — people (blue) + their agents (violet)": the daily people (blue)
  # and their agents (violet) chart.
  def variations do
    [
      %Variation{
        id: :thirty_days,
        description: "30 days of people and their agents",
        attributes: %{id: "bars-30", series: series(fn i -> {rem(i * 7, 4), rem(i * 5, 3)} end)}
      },
      %Variation{
        id: :all_zero,
        description: "No activity yet: every bar at 0%",
        attributes: %{id: "bars-zero", series: series(fn _i -> {0, 0} end)}
      }
    ]
  end

  defp series(counts) do
    for i <- 0..29 do
      {people, agents} = counts.(i)
      %{date: Date.add(~D[2026-09-26], i), people: people, agents: agents}
    end
  end
end
