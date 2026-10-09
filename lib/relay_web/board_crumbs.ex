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
          optional(:icon) => String.t(),
          optional(:patch) => boolean()
        }

  @doc "The board page: `Boards / <board>` — the board name is the page's title."
  @spec board(%{name: String.t(), slug: String.t()}) :: [crumb()]
  def board(_board), do: [boards()]

  @doc "A settings section or the Runners page: `Boards / <board> / Settings / <title>`."
  @spec settings_section(%{name: String.t(), slug: String.t()}) :: [crumb()]
  def settings_section(board), do: [boards(), board_crumb(board), settings(board)]

  @doc """
  The flow editor and metrics: `Boards / <board> / Settings / Stages / <flow>` — the Stages crumb
  deep-links to the row of the stage the flow works in, where the flow lives (RE431).
  """
  @spec flows(%{name: String.t(), slug: String.t()}, %{stage_id: integer()}) :: [crumb()]
  def flows(board, flow), do: settings_section(board) ++ [stages_crumb(board, flow)]

  @doc """
  The mockup viewer (RE380): `Boards / <board> / <card title>` — the page's title is "Mockups".
  The card crumb is a `patch` to `card_to` (the card's drawer URL), so it leaves the viewer
  without remounting the board.
  """
  @spec card_mockups(%{name: String.t(), slug: String.t()}, %{title: String.t()}, String.t()) :: [crumb()]
  def card_mockups(board, card, card_to) do
    [boards(), board_crumb(board), %{id: "top-bar-crumb-card", label: card.title, to: card_to, patch: true}]
  end

  defp boards do
    %{id: "top-bar-crumb-boards", label: "Boards", to: ~p"/boards", icon: "hero-squares-2x2"}
  end

  defp board_crumb(board) do
    %{id: "top-bar-crumb-board", label: board.name, to: ~p"/board/#{board.slug}"}
  end

  defp settings(board) do
    %{id: "top-bar-crumb-settings", label: "Settings", to: ~p"/board/#{board.slug}/settings"}
  end

  defp stages_crumb(board, %{stage_id: stage_id}) do
    %{
      id: "top-bar-crumb-stages",
      label: BoardSettingsLive.section_label(:stages),
      to: ~p"/board/#{board.slug}/settings?section=stages" <> "#stage-#{stage_id}-row"
    }
  end
end
