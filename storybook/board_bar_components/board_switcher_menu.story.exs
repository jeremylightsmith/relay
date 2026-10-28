defmodule Storybook.BoardBarComponents.BoardSwitcherMenu do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  # RE497 — card mockup "B — one row: board name opens the switcher, ⋯ holds views", frame
  # "B — tap the board name". In the app `HamacaWeb.BoardSwitcherComponent` renders this and
  # loads `boards` on the first open; here `open: true` drops `hidden` so the menu shows.

  def function, do: &HamacaWeb.BoardBarComponents.board_switcher_menu/1
  def render_source, do: :function
  def container, do: {:iframe, style: "height: 420px;"}

  def template do
    """
    <div style="display:flex;width:320px;">
      <.psb-variation/>
    </div>
    """
  end

  @board %{slug: "payments", name: "Payments"}

  defp row(slug, key, name, opts \\ []) do
    Map.merge(
      %{slug: slug, key: key, name: name, starred?: false, ai_active?: false, needs_you_count: 0},
      Map.new(opts)
    )
  end

  def variations do
    [
      %Variation{id: :closed, attributes: %{board: @board}},
      %Variation{id: :open_loading, attributes: %{board: @board, boards: nil, open: true}},
      %Variation{
        id: :open_loaded,
        attributes: %{
          board: @board,
          open: true,
          boards: [
            row("hamaca", "RE", "Hamaca", starred?: true, ai_active?: true, needs_you_count: 4),
            row("payments", "PAY", "Payments", needs_you_count: 2),
            row("mobile", "MOB", "Mobile app", ai_active?: true),
            row("website", "WEB", "Website")
          ]
        }
      }
    ]
  end
end
