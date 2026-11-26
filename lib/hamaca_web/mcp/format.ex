defmodule HamacaWeb.Mcp.Format do
  @moduledoc """
  The reply pieces the MCP tools share (RE519), each defined once: absolute board and card
  links, the `Name (KEY)` label, what a waiting card needs from you, and the sentence for a board
  name that matched several boards or none.
  """

  use HamacaWeb, :verified_routes

  alias Hamaca.Cards
  alias HamacaWeb.TimeAgo
  alias Schemas.Board

  @doc "The board's absolute web URL."
  @spec board_url(Board.t()) :: String.t()
  def board_url(%Board{slug: slug}), do: url(~p"/board/#{slug}")

  @doc "The card's absolute web URL — the board with its drawer open on `ref`."
  @spec card_url(Board.t(), String.t()) :: String.t()
  def card_url(%Board{slug: slug}, ref), do: url(~p"/board/#{slug}?card=#{ref}")

  @doc ~s{A card as `"[REF](card_url) Title"`.}
  @spec card_link(Board.t(), map()) :: String.t()
  def card_link(%Board{} = board, card) do
    ref = Cards.ref(board, card)
    "[#{ref}](#{card_url(board, ref)}) #{card.title}"
  end

  @doc ~s{A waiting card's line body: `"[REF](card_url) Title — <needed> · <ago>"`.}
  @spec waiting_row(Board.t(), map(), DateTime.t()) :: String.t()
  def waiting_row(%Board{} = board, %{card: card} = row, %DateTime{} = now) do
    "#{card_link(board, card)} — #{needed(row)} · #{TimeAgo.ago(now, Cards.waiting_since(card))}"
  end

  @doc ~s{`"Name (KEY)"`.}
  @spec board_label(Board.t()) :: String.t()
  def board_label(%Board{name: name, key: key}), do: "#{name} (#{key})"

  @doc """
  What a `Hamaca.Cards.needs_you_feed/1` row needs: `"review"` for `:in_review`, else its
  question count (`"1 question"` unless the questions are structured).
  """
  @spec needed(map()) :: String.t()
  def needed(%{card: %{status: :in_review}}), do: "review"
  def needed(%{questions: [_, _ | _] = questions}), do: "#{length(questions)} questions"
  def needed(_row), do: "1 question"

  @doc """
  The sentence for a board name that `Hamaca.Boards.resolve_board/2` could not settle. Not found
  lists only the caller's boards, so a foreign board reads exactly like a missing one.
  """
  @spec board_choice_error(String.t(), {:ambiguous | :not_found, [Board.t()]}) :: String.t()
  def board_choice_error(query, {:ambiguous, boards}) do
    "#{count_word(length(boards))} boards match '#{query}': #{labels(boards)}. Which one?"
  end

  def board_choice_error(query, {:not_found, []}) do
    "No board matches '#{query}'. You aren't a member of any Hamaca boards yet."
  end

  def board_choice_error(query, {:not_found, boards}) do
    "No board matches '#{query}'. Your boards: #{labels(boards)}."
  end

  @doc ~s(Labels joined as English: `"A, B and C"`, sorted by name.)
  @spec labels([Board.t()]) :: String.t()
  def labels(boards) do
    boards
    |> Enum.sort_by(&{String.downcase(&1.name), &1.id})
    |> Enum.map(&board_label/1)
    |> join_and()
  end

  defp join_and([one]), do: one
  defp join_and(items), do: Enum.join(Enum.drop(items, -1), ", ") <> " and " <> List.last(items)

  @count_words ~w(Zero One Two Three Four Five Six Seven Eight Nine)

  defp count_word(n) when n < 10, do: Enum.at(@count_words, n)
  defp count_word(n), do: Integer.to_string(n)
end
