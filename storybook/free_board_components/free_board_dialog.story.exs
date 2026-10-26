defmodule Storybook.FreeBoardComponents.FreeBoardDialog do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.FreeBoardComponents.free_board_dialog/1
  def render_source, do: :function

  # The dialog is a daisyUI `modal-open` (a fixed overlay), so each variation gets its own iframe.
  def container, do: {:iframe, style: "height: 640px;"}

  # RE471, card mockup "Over limit — one-time 'Which board stays editable?' dialog".
  def variations do
    boards = boards()

    [
      %Variation{
        id: :editable_selected,
        description: "Just opened — the most active board preselected",
        attributes: %{boards: boards, selected: 1, editable_id: 1, upgrade_price: "$20", upgrade_href: "/account/billing"}
      },
      %Variation{
        id: :other_selected,
        description: "Another board selected — Keep names it; the footnote still names today's editable board",
        attributes: %{boards: boards, selected: 2, editable_id: 1, upgrade_price: "$20", upgrade_href: "/account/billing"}
      },
      %Variation{
        id: :embedded,
        description: "Embedded in the app — no Upgrade instead button",
        attributes: %{boards: boards, selected: 1, editable_id: 1, upgrade_price: "$20", upgrade_href: nil}
      }
    ]
  end

  defp boards do
    now = DateTime.utc_now()

    [
      %{
        id: 1,
        slug: "relay-engineering",
        name: "Relay Engineering",
        editable?: true,
        active_at: DateTime.add(now, -2, :hour)
      },
      %{id: 2, slug: "acme-checkout", name: "Acme Checkout", editable?: false, active_at: DateTime.add(now, -3, :day)},
      %{id: 3, slug: "hamaca-launch", name: "Hamaca launch", editable?: false, active_at: DateTime.add(now, -5, :day)},
      %{id: 4, slug: "side-project", name: "Side project", editable?: false, active_at: DateTime.add(now, -14, :day)}
    ]
  end
end
