defmodule Storybook.Components.CoreComponents.Breadcrumbs do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.breadcrumbs/1
  def render_source, do: :function

  # The top bar renders the page's own title right after the trail; the template stands in for it.
  def template do
    """
    <div class="flex items-center gap-[7px] text-[13px] font-medium">
      <.psb-variation/>
      <span class="truncate">Current page</span>
    </div>
    """
  end

  # Literal crumbs, not `RelayWeb.BoardCrumbs`: the storybook validator evaluates
  # `variations/0` at compile time, and BoardCrumbs' verified routes need a running endpoint.
  def variations do
    boards = %{
      id: "top-bar-crumb-boards",
      label: "Boards",
      to: "/boards",
      icon: "hero-squares-2x2"
    }

    board = %{id: "top-bar-crumb-board", label: "Payments", to: "/board/payments"}
    settings = %{id: "top-bar-crumb-settings", label: "Settings", to: "/board/payments/settings"}

    flows = %{
      id: "top-bar-crumb-flows",
      label: "Flows",
      to: "/board/payments/settings?section=flows"
    }

    [
      %Variation{
        id: :board,
        description: "Board page — Boards / <board> (the board name is the title)",
        attributes: %{id: "crumbs-board", crumbs: scoped("board", [boards])}
      },
      %Variation{
        id: :settings_section,
        description: "Settings section or Runners — Boards / <board> / Settings / <section>",
        attributes: %{
          id: "crumbs-settings",
          crumbs: scoped("settings", [boards, board, settings])
        }
      },
      %Variation{
        id: :flow_deep,
        description:
          "Flow editor / metrics — Boards / <board> / Settings / Flows / <flow>; below md the " <>
            "middle crumbs collapse to …",
        attributes: %{
          id: "crumbs-flow",
          crumbs: scoped("flow", [boards, board, settings, flows])
        }
      }
    ]
  end

  # Three variations share one page, so prefix the crumb ids to keep DOM ids unique.
  defp scoped(prefix, crumbs), do: Enum.map(crumbs, &%{&1 | id: "#{prefix}-#{&1.id}"})
end
