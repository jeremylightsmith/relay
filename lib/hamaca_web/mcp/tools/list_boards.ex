defmodule HamacaWeb.Mcp.Tools.ListBoards do
  @moduledoc """
  `list_boards` (RE519): the user's boards in display order, each with how many cards wait on
  them — counted from `Hamaca.Cards.needs_you_feed/1`, so it agrees with `board_status`.
  """

  @behaviour HamacaWeb.Mcp.Tool

  alias Hamaca.Boards
  alias Hamaca.Cards
  alias HamacaWeb.Mcp.Format

  @impl true
  def name, do: "list_boards"

  @impl true
  def description do
    "List the Hamaca boards the user is a member of, with each board's key, slug, how many cards " <>
      "are waiting on the user, and its link. Use it when the user asks which boards or projects " <>
      "they have, or to find the right board before calling board_status. " <>
      "Always name the board and link each card in your reply."
  end

  @impl true
  def input_schema, do: %{type: "object", properties: %{}}

  @impl true
  def call(user, _args) do
    case Boards.list_boards_for_display(user) do
      [] ->
        {:ok, "You aren't a member of any Hamaca boards yet."}

      rows ->
        waiting = user |> Cards.needs_you_feed() |> Enum.frequencies_by(& &1.card.board_id)

        lines =
          for %{board: board} <- Enum.uniq_by(rows, & &1.board.id) do
            "- **#{board.name}** (#{board.key}) · slug `#{board.slug}` · " <>
              "#{Map.get(waiting, board.id, 0)} waiting on you · #{Format.board_url(board)}"
          end

        {:ok, Enum.join(lines, "\n")}
    end
  end
end
