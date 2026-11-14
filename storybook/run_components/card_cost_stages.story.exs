defmodule Storybook.RunComponents.CardCostStages do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.RunComponents.card_cost_stages/1
  def render_source, do: :function

  # RE514 — the Run tab's BY STAGE panel, with the card mockup's numbers. Plain map, no Repo.
  defp mockup_cost(overrides) do
    Map.merge(
      %{
        total: Decimal.new("5.54"),
        unpriced: 2,
        in_flight?: true,
        runs: 6,
        by_stage: [
          %{label: "Design", runs: 3, failed: 0, cost: Decimal.new("1.17"), bar: 29},
          %{label: "Spec", runs: 1, failed: 0, cost: Decimal.new("0.35"), bar: 9},
          %{label: "Code", runs: 2, failed: 1, cost: Decimal.new("4.02"), bar: 100}
        ],
        failed: %{runs: 2, cost: Decimal.new("2.17"), bar: 54}
      },
      overrides
    )
  end

  def variations do
    [
      %Variation{
        id: :with_failed,
        description: "Three stages and the dashed failed / cancelled row",
        attributes: %{cost: mockup_cost(%{})}
      },
      %Variation{
        id: :no_failed,
        description: "Nothing failed or cancelled: no failed row",
        attributes: %{
          cost:
            mockup_cost(%{
              by_stage: [
                %{label: "Design", runs: 1, failed: 0, cost: Decimal.new("1.03"), bar: 56},
                %{label: "Spec", runs: 1, failed: 0, cost: Decimal.new("0.31"), bar: 17},
                %{label: "Code", runs: 1, failed: 0, cost: Decimal.new("1.84"), bar: 100}
              ],
              failed: nil
            })
        }
      }
    ]
  end
end
