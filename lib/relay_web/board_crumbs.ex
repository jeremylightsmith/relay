defmodule RelayWeb.BoardCrumbs do
  @moduledoc """
  The top-bar breadcrumb trails for the board and its settings pages (RE334) — the ONE place
  each crumb's label, path and DOM id is written. Pages pass the result to `Layouts.app`'s
  `crumbs` attr, which renders it with `CoreComponents.breadcrumbs/1`; the page's own
  `<:title>` is the final, un-linked segment, so the current page is never in these lists.

  Runners sits under Settings because the settings rail lists it (ENGINE → Runners).

  No `use Boundary` — a pure web-layer helper inside the `RelayWeb` boundary, like
  `RelayWeb.FlowLayout`.
  """
  use RelayWeb, :verified_routes

  alias RelayWeb.BoardSettingsLive

  @type crumb :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          required(:to) => String.t(),
          optional(:icon) => String.t()
        }

  @doc "The board page: `Boards / <board>` — the board name is the page's title."
  @spec board(%{name: String.t(), slug: String.t()}) :: [crumb()]
  def board(_board), do: [boards()]

  @doc "A settings section or the Runners page: `Boards / <board> / Settings / <title>`."
  @spec settings_section(%{name: String.t(), slug: String.t()}) :: [crumb()]
  def settings_section(board), do: [boards(), board_crumb(board), settings(board)]

  @doc "The flow editor and metrics: `Boards / <board> / Settings / Flows / <flow>`."
  @spec flows(%{name: String.t(), slug: String.t()}) :: [crumb()]
  def flows(board), do: settings_section(board) ++ [flows_crumb(board)]

  defp boards do
    %{id: "top-bar-crumb-boards", label: "Boards", to: ~p"/boards", icon: "hero-squares-2x2"}
  end

  defp board_crumb(board) do
    %{id: "top-bar-crumb-board", label: board.name, to: ~p"/board/#{board.slug}"}
  end

  defp settings(board) do
    %{id: "top-bar-crumb-settings", label: "Settings", to: ~p"/board/#{board.slug}/settings"}
  end

  defp flows_crumb(board) do
    %{
      id: "top-bar-crumb-flows",
      label: BoardSettingsLive.section_label(:flows),
      to: ~p"/board/#{board.slug}/settings?section=flows"
    }
  end
end
