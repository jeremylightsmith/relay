defmodule Storybook.RunComponents.CardCostChip do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.RunComponents.card_cost_chip/1
  def render_source, do: :function

  # RE514 — the drawer header's card-cost chip. `cost` is `Hamaca.Runs.card_cost/1`'s map; only
  # `total`, `unpriced` and `in_flight?` matter to the chip. A click sends `drawer_tab` → run.
  def variations do
    [
      %Variation{
        id: :settled,
        description: "Every run settled and priced: the bare total",
        attributes: %{
          id: "card-cost-chip-settled",
          cost: %{total: Decimal.new("3.18"), unpriced: 0, in_flight?: false, runs: 3, by_stage: [], failed: nil}
        }
      },
      %Variation{
        id: :in_flight_unpriced,
        description: "A run in flight with 2 executions unpriced: pulse dot and a ≥ figure",
        attributes: %{
          id: "card-cost-chip-in-flight",
          cost: %{total: Decimal.new("5.54"), unpriced: 2, in_flight?: true, runs: 6, by_stage: [], failed: nil}
        }
      }
    ]
  end
end
