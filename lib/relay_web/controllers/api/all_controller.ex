defmodule RelayWeb.Api.AllController do
  @moduledoc """
  The native app's cross-board decision surface (RLY-80): the aggregated needs-you feed
  the inbox renders, plus the human's approve/reject/answer actions. Authenticated by
  `RelayWeb.ApiUserAuth` (user bearer token), acting as `{:user, id}` — never as the agent.
  """

  use RelayWeb, :controller

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias RelayWeb.Api.CardJSON
  alias RelayWeb.Api.FeedJSON

  action_fallback RelayWeb.Api.FallbackController

  def feed(conn, _params) do
    rows = Cards.needs_you_feed(conn.assigns.current_user)

    conn
    |> put_view(json: FeedJSON)
    |> render(:feed, rows: rows)
  end

  def approve(conn, %{"ref" => ref} = params) do
    with {:ok, board, card} <- Cards.resolve_ref(conn.assigns.current_user, ref, params["board"]),
         {:ok, card} <- Cards.approve(card, conn.assigns.actor) do
      render_card(conn, board, card)
    end
  end

  def reject(conn, %{"ref" => ref} = params) do
    with {:ok, note} <- reject_note(params),
         {:ok, board, card} <- Cards.resolve_ref(conn.assigns.current_user, ref, params["board"]),
         {:ok, card} <- Cards.reject(card, note, conn.assigns.actor) do
      render_card(conn, board, card)
    end
  end

  def answer(conn, %{"ref" => ref} = params) do
    with {:ok, board, card} <- Cards.resolve_ref(conn.assigns.current_user, ref, params["board"]),
         {:ok, answer} <- compose(card, params),
         {:ok, card} <- Cards.answer_input(card, answer, conn.assigns.actor) do
      render_card(conn, board, card)
    end
  end

  # The note is required for rejects (spec: 422 when missing).
  defp reject_note(%{"note" => note}) when is_binary(note) do
    if String.trim(note) == "", do: {:error, :missing_note}, else: {:ok, note}
  end

  defp reject_note(_params), do: {:error, :missing_note}

  # The stepper's structured picks and the flat free-text fallback both compose down to the one
  # Q->A comment Cards.answer_input/3 already records — "structured" is the input shape, not a
  # new persistence format.
  defp compose(%Schemas.Card{status: :needs_input} = card, %{"answers" => answers})
       when is_list(answers) and answers != [] do
    case Cards.latest_questions(card) do
      nil ->
        {:error, :invalid_request}

      questions ->
        values = answers |> Enum.with_index() |> Map.new(fn {a, i} -> {i, answer_value(a)} end)
        {:ok, Cards.compose_answer(questions, values)}
    end
  end

  defp compose(%Schemas.Card{status: :needs_input}, %{"answer" => answer}) when is_binary(answer) do
    if String.trim(answer) == "", do: {:error, :invalid_request}, else: {:ok, answer}
  end

  defp compose(%Schemas.Card{status: :needs_input}, _params), do: {:error, :invalid_request}
  defp compose(%Schemas.Card{}, _params), do: {:error, :not_needs_input}

  # A missing/malformed pick composes an empty answer, exactly like a skipped step in the
  # web stepper.
  defp answer_value(%{"value" => value}) when is_binary(value), do: value
  defp answer_value(_answer), do: ""

  # The acted-on card, so the client updates in place (RLY-88's auto-advance then just re-reads
  # the feed). Reuses the board API's card envelope verbatim.
  defp render_card(conn, board, card) do
    conn
    |> put_view(json: CardJSON)
    |> render(:show,
      board: board,
      card: card,
      stages: Boards.list_stages(board),
      timeline: Activity.list_timeline(card)
    )
  end
end
