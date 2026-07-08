defmodule RelayWeb.Api.CardController do
  use RelayWeb, :controller

  alias Relay.Activity
  alias Relay.Cards

  action_fallback RelayWeb.Api.FallbackController

  def index(conn, _params) do
    board = conn.assigns.current_board
    render(conn, :index, board: board, cards: Cards.list_cards(board))
  end

  def show(conn, %{"ref" => ref}) do
    board = conn.assigns.current_board

    case Cards.get_card_by_ref(board, ref) do
      %Schemas.Card{} = card -> render(conn, :show, board: board, card: card, timeline: Activity.list_timeline(card))
      nil -> {:error, :not_found}
    end
  end

  def update(conn, %{"ref" => ref} = params) do
    board = conn.assigns.current_board

    with %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref),
         {:ok, card} <- update_fields(card, params),
         {:ok, card} <- update_status(card, params),
         {:ok, card} <- update_owners(card, params) do
      render(conn, :show, board: board, card: card, timeline: Activity.list_timeline(card))
    else
      nil -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
      :error -> {:error, :invalid_request}
    end
  end

  defp update_fields(card, params) do
    case Map.take(params, ["title", "description", "tag"]) do
      empty when map_size(empty) == 0 -> {:ok, card}
      fields -> Cards.update_card(card, fields)
    end
  end

  defp update_status(card, %{"status" => status} = params) do
    attrs = params |> Map.take(["progress"]) |> Map.put("status", status)
    Cards.set_status(card, attrs, :agent)
  end

  defp update_status(card, _params), do: {:ok, card}

  defp update_owners(card, %{"owners" => owners}) when is_list(owners) do
    owners
    |> Enum.map(&parse_actor/1)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, actor}, {:ok, acc} -> {:cont, {:ok, [actor | acc]}}
      :error, _acc -> {:halt, :error}
    end)
    |> case do
      {:ok, actors} -> Cards.set_owners(card, Enum.reverse(actors), :agent)
      :error -> :error
    end
  end

  defp update_owners(card, _params), do: {:ok, card}

  defp parse_actor("agent"), do: {:ok, :agent}

  defp parse_actor("user:" <> id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, {:user, int}}
      _ -> :error
    end
  end

  defp parse_actor(_), do: :error
end
