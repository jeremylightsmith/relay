defmodule RelayWeb.Api.AllController do
  @moduledoc """
  The native app's cross-board decision surface (RLY-80): the aggregated needs-you feed
  the inbox renders, the human's approve/reject/answer actions, and (RLY-126) the native
  New-card sheet's create path. Authenticated by `RelayWeb.ApiUserAuth` (user bearer token),
  acting as `{:user, id}` — never as the agent.
  """

  use RelayWeb, :controller

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias RelayWeb.Api.CardJSON
  alias RelayWeb.Api.FeedJSON

  action_fallback RelayWeb.Api.FallbackController

  # RLY-126 · BOARD-04 — the native New-card sheet's create path. A narrow, deliberate
  # extension of this ADR-0001-scoped surface: resolve board + top-level stage, then the
  # same Cards.create_card/3 the web composer uses, attributed to the signed-in human.
  def create(conn, params) do
    with {:ok, board} <- resolve_board(conn.assigns.current_user, params["board"]),
         {:ok, stage} <- resolve_intake_stage(board, params["stage"]),
         {:ok, attrs} <- create_attrs(params),
         {:ok, card} <- Cards.create_card(stage, attrs, conn.assigns.actor) do
      conn
      |> put_status(:created)
      |> render_card(board, card)
    end
  end

  def feed(conn, _params) do
    rows = Cards.needs_you_feed(conn.assigns.current_user)

    conn
    |> put_view(json: FeedJSON)
    |> render(:feed, rows: rows)
  end

  # RLY-98: the native card screen's mount fetch — the light card shape (incl. pr_url),
  # not show/1's heavy timeline/spec/plan. RLY-91 extends this when the spec sheet lands.
  def show(conn, %{"ref" => ref} = params) do
    case Cards.resolve_ref(conn.assigns.current_user, ref, params["board"]) do
      {:ok, board, card} ->
        conn
        |> put_view(json: CardJSON)
        |> render(:summary, board: board, card: card, stages: Boards.list_stages(board))

      {:error, _reason} = error ->
        error
    end
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

  # Board by slug among the user's boards. Unknown slug, no membership, or a missing
  # param are all the same 404 — don't leak existence (Cards.resolve_ref/3's posture).
  defp resolve_board(user, slug) when is_binary(slug) do
    case Enum.find(Boards.list_boards(user), &(&1.slug == slug)) do
      nil -> {:error, :not_found}
      board -> {:ok, board}
    end
  end

  defp resolve_board(_user, _slug), do: {:error, :not_found}

  # Stage by name among the board's TOP-LEVEL stages only: substages (Code:Review …) are
  # gates, not intake points (RLY-126 decision 2), so their names are invalid here.
  defp resolve_intake_stage(board, name) when is_binary(name) do
    board
    |> Boards.list_stages()
    |> Enum.find(&(is_nil(&1.parent_id) and &1.name == name))
    |> case do
      nil -> {:error, :invalid_stage}
      stage -> {:ok, stage}
    end
  end

  defp resolve_intake_stage(_board, _name), do: {:error, :invalid_stage}

  # Blank/missing title is 422 (spec), mirroring reject's missing_note — the generic
  # changeset fallback would 400.
  defp create_attrs(%{"title" => title} = params) when is_binary(title) do
    if String.trim(title) == "" do
      {:error, :missing_title}
    else
      {:ok, Map.take(params, ["title", "description"])}
    end
  end

  defp create_attrs(_params), do: {:error, :missing_title}

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
