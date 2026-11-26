defmodule HamacaWeb.Mcp.Tools.BoardStatus do
  @moduledoc """
  `board_status` (RE519): one board's `Hamaca.Cards.board_digest/3`, baton first — waiting on
  you, agents working, shipped this week — every card with its ref and link.
  """

  @behaviour HamacaWeb.Mcp.Tool

  alias Hamaca.Boards
  alias Hamaca.Cards
  alias HamacaWeb.Mcp.Format

  @section_limit 10

  @doc "The most rows one section shows before linking to the board for the rest."
  @spec section_limit() :: pos_integer()
  def section_limit, do: @section_limit

  @impl true
  def name, do: "board_status"

  @impl true
  def description do
    "Summarize one Hamaca board: the cards waiting on the user (questions to answer, reviews to " <>
      "approve), the cards agents are working on, and what shipped this week. Use it when the user " <>
      "asks \"what's going on with <board/project>\" or how a board is doing. `board` is the " <>
      "board's name, key or slug. Always name the board and link each card in your reply."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{board: %{type: "string", description: "The board's name, key or slug, e.g. \"relay\"."}},
      required: ["board"]
    }
  end

  @impl true
  def call(user, %{"board" => query}) when is_binary(query) do
    case Boards.resolve_board(user, query) do
      {:ok, board} ->
        now = DateTime.utc_now()
        {:ok, render(board, Cards.board_digest(user, board, now), now)}

      {:error, choice} ->
        {:error, Format.board_choice_error(query, choice)}
    end
  end

  def call(_user, _args), do: {:error, "board is required: pass the board's name, key or slug."}

  defp render(board, %{waiting: waiting, working: working, shipped: shipped}, now) do
    summary =
      "#{board.name} has #{cards(length(waiting))} waiting on you, #{length(working)} that agents are " <>
        "working on, and #{length(shipped)} shipped this week."

    sections = [
      section(board, "Waiting on you", waiting, &Format.waiting_row(board, &1, now)),
      section(board, "Agents working", working, &working_row(board, &1)),
      section(board, "Shipped this week", shipped, &Format.card_link(board, &1))
    ]

    Enum.join([summary | sections] ++ ["Board: #{Format.board_url(board)}"], "\n\n")
  end

  defp cards(1), do: "1 card"
  defp cards(n), do: "#{n} cards"

  defp section(_board, title, [], _row), do: "**#{title} (0)**\n- Nothing right now."

  defp section(board, title, items, row) do
    {shown, rest} = Enum.split(items, @section_limit)
    rows = Enum.map(shown, &("- " <> row.(&1)))
    more = if rest == [], do: [], else: ["- …and #{length(rest)} more: #{Format.board_url(board)}"]

    Enum.join(["**#{title} (#{length(items)})**" | rows ++ more], "\n")
  end

  defp working_row(board, %{card: card, stage: stage}) do
    "#{Format.card_link(board, card)} — #{stage.name}#{tasks(card)}"
  end

  defp tasks(card) do
    case Cards.sub_task_progress(card) do
      %{total: 0} -> ""
      %{done: done, total: total} -> " · #{done}/#{total} tasks"
    end
  end
end
