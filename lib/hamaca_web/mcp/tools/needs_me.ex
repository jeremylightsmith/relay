defmodule HamacaWeb.Mcp.Tools.NeedsMe do
  @moduledoc """
  `needs_me` (RE519): `Hamaca.Cards.needs_you_feed/1` grouped by board — the board waiting
  longest first, and the longest-waiting card first inside each board.
  """

  @behaviour HamacaWeb.Mcp.Tool

  alias Hamaca.Cards
  alias HamacaWeb.Mcp.Format

  @impl true
  def name, do: "needs_me"

  @impl true
  def description do
    "List every card across the user's Hamaca boards that is waiting on them — questions to " <>
      "answer and reviews to approve — oldest first, grouped by board. Use it when the user asks " <>
      ~s("anything need me?" or "what's waiting on me?". ) <>
      "Always name the board and link each card in your reply."
  end

  @impl true
  def input_schema, do: %{type: "object", properties: %{}}

  @impl true
  def call(user, _args) do
    case Cards.needs_you_feed(user) do
      [] -> {:ok, "Nothing is waiting on you right now."}
      rows -> {:ok, render(rows, DateTime.utc_now())}
    end
  end

  defp render(rows, now) do
    rows
    |> Enum.sort_by(&Cards.waiting_since(&1.card), DateTime)
    # group_by keeps each group's rows in input order, so each is oldest first.
    |> Enum.group_by(& &1.card.board_id)
    |> Map.values()
    |> Enum.sort_by(&Cards.waiting_since(hd(&1).card), DateTime)
    |> Enum.map_join("\n\n", &group(&1, now))
  end

  defp group([%{card: %{board: board}} | _] = rows, now) do
    Enum.join(["**#{Format.board_label(board)}**" | Enum.map(rows, &("- " <> Format.waiting_row(board, &1, now)))], "\n")
  end
end
