defmodule RelayWeb.Api.BoardListJSON do
  @moduledoc """
  The native board switcher's row shape (RE376, `GET /api/all/boards`). Every fact comes
  from `Relay.Cards.list_board_summaries/1` — the same rows the web boards home renders —
  so the switcher's counts never drift from BOARDS-00. `needs_you_count` is the mobile
  two-type count (ADR 0005), never the web's three-type sum. Rows come in the user's display
  order (starred first, then A–Z) and carry the personal `starred` flag (RE395) and the per-member push `muted` flag (RE406).
  """

  def boards(%{summaries: summaries}), do: %{data: Enum.map(summaries, &row/1)}

  @doc "The switcher's star reply (RE396, `POST /api/all/boards/:slug/star`): the value set."
  def star(%{slug: slug, starred: starred}), do: %{data: %{slug: slug, starred: starred}}

  @doc "The switcher's mute reply (RE406, `POST /api/all/boards/:slug/mute`): the value set."
  def mute(%{slug: slug, muted: muted}), do: %{data: %{slug: slug, muted: muted}}

  defp row(summary) do
    %{
      name: summary.name,
      slug: summary.slug,
      key: summary.key,
      needs_you_count: summary.needs_you_two_type,
      stage_count: summary.stage_count,
      card_count: summary.card_count,
      ai_active: summary.ai_active?,
      starred: summary.starred?,
      muted: summary.muted?
    }
  end
end
