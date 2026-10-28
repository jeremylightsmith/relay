defmodule Storybook.BoardBarComponents.BoardMoreMenu do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  # RE497 — the board bar's ⋯ menu. Card mockups "B — one row: board name opens the switcher,
  # ⋯ holds views" (phones: the View section shows) and "Wide B — the phone's ⋯ on desktop
  # too" (`sm`+: Agent log, Board settings, Setup). Resize the iframe below 640px to see the
  # phone set. `open: true` drops `hidden` so the menu shows.

  def function, do: &HamacaWeb.BoardBarComponents.board_more_menu/1
  def render_source, do: :function
  def container, do: {:iframe, style: "height: 440px;"}

  def template do
    """
    <div style="display:flex;justify-content:flex-end;width:300px;">
      <.psb-variation/>
    </div>
    """
  end

  @base %{
    board_slug: "payments",
    active_view: :board,
    show_logs: true,
    settings_path: "/board/payments/settings",
    open: true
  }

  def variations do
    [
      %Variation{id: :phone_and_wide_set, attributes: @base},
      %Variation{
        id: :with_setup,
        attributes: Map.put(@base, :setup, %{finished?: false, closed?: false, position: 3, total: 7})
      },
      %Variation{
        id: :logs_open,
        attributes: Map.merge(@base, %{active_view: :story_map, logs_open: true})
      },
      %Variation{
        id: :closed_with_setup_dot,
        attributes: %{
          board_slug: "payments",
          active_view: :board,
          setup: %{finished?: true, closed?: false, position: 7, total: 7}
        }
      }
    ]
  end
end
