defmodule RelayWeb.Api.CardController do
  use RelayWeb, :controller

  alias Relay.Activity
  alias Relay.Attachments
  alias Relay.Boards
  alias Relay.Cards

  action_fallback RelayWeb.Api.FallbackController

  def index(conn, params) do
    board = conn.assigns.current_board
    stages = Boards.list_stages(board)
    render(conn, :index, board: board, stages: stages, cards: index_cards(board, stages, params))
  end

  def create(conn, params) do
    board = conn.assigns.current_board

    with {:ok, stage} <- resolve_create_stage(board, params["stage"]),
         {:ok, card} <- Cards.create_card(stage, params, :agent) do
      conn
      |> put_status(:created)
      |> render(:show,
        board: board,
        card: card,
        stages: Boards.list_stages(board),
        timeline: Activity.list_timeline(card)
      )
    end
  end

  def show(conn, %{"ref" => ref}) do
    board = conn.assigns.current_board

    case Cards.get_card_by_ref(board, ref) do
      %Schemas.Card{} = card ->
        render(conn, :show,
          board: board,
          card: card,
          stages: Boards.list_stages(board),
          timeline: Activity.list_timeline(card)
        )

      nil ->
        {:error, :not_found}
    end
  end

  def update(conn, %{"ref" => ref} = params) do
    board = conn.assigns.current_board

    with %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref),
         {:ok, card} <- update_fields(card, params),
         {:ok, card} <- update_status(card, params),
         {:ok, card} <- update_owners(card, params),
         {:ok, card} <- update_ai_result(card, params),
         {:ok, card} <- update_sub_tasks(card, params) do
      render(conn, :show,
        board: board,
        card: card,
        stages: Boards.list_stages(board),
        timeline: Activity.list_timeline(card)
      )
    else
      nil -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
      :error -> {:error, :invalid_request}
    end
  end

  defp update_fields(card, params) do
    case Map.take(params, [
           "title",
           "description",
           "acceptance_criteria",
           "spec",
           "tag",
           "branch",
           "plan",
           "pr_url"
         ]) do
      empty when map_size(empty) == 0 -> {:ok, card}
      fields -> Cards.update_card(card, fields)
    end
  end

  defp update_ai_result(card, %{"ai_result" => ai_result}) when is_map(ai_result) do
    Cards.update_ai_result(card, ai_result)
  end

  defp update_ai_result(_card, %{"ai_result" => _}), do: :error
  defp update_ai_result(card, _params), do: {:ok, card}

  defp update_sub_tasks(card, %{"sub_tasks" => sub_tasks}) when is_list(sub_tasks) do
    Cards.set_sub_tasks(card, sub_tasks)
  end

  defp update_sub_tasks(_card, %{"sub_tasks" => _}), do: :error
  defp update_sub_tasks(card, _params), do: {:ok, card}

  defp update_status(card, %{"status" => status}) do
    Cards.set_status_snapped(card, %{"status" => status}, :agent)
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

  def move(conn, %{"ref" => ref} = params) do
    board = conn.assigns.current_board

    with %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref),
         {:ok, index} <- move_index(params),
         %Schemas.Stage{} = stage <- get_stage(board, params["stage"]),
         {:ok, card} <- Cards.move_card(card, stage, index, :agent) do
      render(conn, :show,
        board: board,
        card: card,
        stages: Boards.list_stages(board),
        timeline: Activity.list_timeline(card)
      )
    else
      nil -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
      :error -> {:error, :invalid_request}
    end
  end

  def toggle_sub_task(conn, %{"ref" => ref, "id" => id, "done" => done}) when is_boolean(done) do
    board = conn.assigns.current_board

    with %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref),
         {:ok, sub_task_id} <- parse_int_id(id),
         {:ok, card} <- Cards.set_sub_task_done(card, sub_task_id, done) do
      render(conn, :show,
        board: board,
        card: card,
        stages: Boards.list_stages(board),
        timeline: Activity.list_timeline(card)
      )
    else
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def toggle_sub_task(_conn, _params), do: {:error, :invalid_request}

  # An id that doesn't cast to an integer can't match any sub_task; treat it as
  # not-found rather than letting Ecto raise a CastError.
  defp parse_int_id(id) when is_integer(id), do: {:ok, id}

  defp parse_int_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  def comments(conn, %{"ref" => ref, "body" => body}) do
    board = conn.assigns.current_board

    with %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref),
         {:ok, comment} <- Activity.add_comment(card, %{actor: :agent, body: body}) do
      conn |> put_status(:created) |> render(:comment, comment: comment)
    else
      nil -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def comments(_conn, %{"ref" => _ref}), do: {:error, :invalid_request}

  def attachments(conn, %{"ref" => ref, "content_type" => content_type, "data_base64" => data_base64} = params) do
    board = conn.assigns.current_board
    filename = Map.get(params, "filename", "attachment")

    with %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref),
         {:ok, bytes} <- decode_base64(data_base64),
         {:ok, attachment} <-
           Attachments.create_attachment(card, %{
             filename: filename,
             content_type: content_type,
             bytes: bytes
           }) do
      conn |> put_status(:created) |> render(:attachment, attachment: attachment)
    else
      nil -> {:error, :not_found}
      :error -> {:error, :invalid_request}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def attachments(_conn, %{"ref" => _ref}), do: {:error, :invalid_request}

  defp decode_base64(data) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> :error
    end
  end

  defp decode_base64(_data), do: :error

  def needs_input(conn, %{"ref" => ref, "questions" => questions}) when is_list(questions) do
    board = conn.assigns.current_board

    with true <- valid_questions?(questions),
         %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref),
         {:ok, card} <- Cards.request_input(card, questions, :agent) do
      render(conn, :show,
        board: board,
        card: card,
        stages: Boards.list_stages(board),
        timeline: Activity.list_timeline(card)
      )
    else
      false -> {:error, :invalid_request}
      nil -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def needs_input(conn, %{"ref" => ref, "question" => question}) when is_binary(question) do
    board = conn.assigns.current_board

    with %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref),
         {:ok, card} <- Cards.request_input(card, question, :agent) do
      render(conn, :show,
        board: board,
        card: card,
        stages: Boards.list_stages(board),
        timeline: Activity.list_timeline(card)
      )
    else
      nil -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def needs_input(_conn, %{"ref" => _ref}), do: {:error, :invalid_request}

  def approve(conn, %{"ref" => ref}) do
    board = conn.assigns.current_board

    with %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref),
         {:ok, card} <- Cards.approve(card, :agent) do
      render(conn, :show,
        board: board,
        card: card,
        stages: Boards.list_stages(board),
        timeline: Activity.list_timeline(card)
      )
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def reject(conn, %{"ref" => ref} = params) do
    board = conn.assigns.current_board

    with {:ok, note} <- reject_note(params),
         %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref),
         {:ok, card} <- Cards.reject(card, note, :agent) do
      render(conn, :show,
        board: board,
        card: card,
        stages: Boards.list_stages(board),
        timeline: Activity.list_timeline(card)
      )
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # The note is required for rejects (spec: 422 when missing).
  defp reject_note(%{"note" => note}) when is_binary(note) and note != "", do: {:ok, note}
  defp reject_note(_params), do: {:error, :missing_note}

  # No stage given -> the board's first stage in position order (Backlog on
  # the default board). An explicit id that doesn't resolve is a 404 (get_stage
  # returns nil for uncastable or unknown ids).
  defp resolve_create_stage(board, nil) do
    case Boards.list_stages(board) do
      [stage | _] -> {:ok, stage}
      [] -> {:error, :invalid_request}
    end
  end

  defp resolve_create_stage(board, stage_id) do
    case get_stage(board, stage_id) do
      %Schemas.Stage{} = stage -> {:ok, stage}
      nil -> {:error, :not_found}
    end
  end

  # A stage id that doesn't cast to an integer can't match any stage; treat it
  # as not-found rather than letting Ecto raise a CastError.
  defp get_stage(board, stage_id) when is_integer(stage_id), do: Boards.get_stage(board, stage_id)

  defp get_stage(board, stage_id) when is_binary(stage_id) do
    case Integer.parse(stage_id) do
      {int, ""} -> Boards.get_stage(board, int)
      _ -> nil
    end
  end

  defp get_stage(_board, _stage_id), do: nil

  # 1-based `position` from the API maps to move_card's 0-based index; a
  # missing position appends (move_card clamps a large index to the end).
  defp move_index(%{"position" => p}) when is_integer(p), do: {:ok, p - 1}

  defp move_index(%{"position" => p}) when is_binary(p) do
    case Integer.parse(p) do
      {int, ""} -> {:ok, int - 1}
      _ -> :error
    end
  end

  defp move_index(_params), do: {:ok, 1_000_000}

  # RLY-67: the card index drops the top-level Done column unless ?include_done is set.
  defp index_cards(board, stages, params) do
    if include_done?(params) do
      Cards.list_cards(board)
    else
      Cards.list_cards(board, exclude_stage_ids: Boards.top_level_done_stage_ids(stages))
    end
  end

  defp include_done?(params), do: params["include_done"] in ["1", "true", true]

  # RLY-71 — light shape check on a structured needs-input payload. A valid payload is a non-empty
  # list of maps, each with a non-blank string prompt, string options (if given), a boolean
  # allow_text (if given), and at least one way to answer (options, or free text).
  defp valid_questions?(questions) do
    questions != [] and Enum.all?(questions, &valid_question?/1)
  end

  defp valid_question?(%{"prompt" => prompt} = question) when is_binary(prompt) do
    options = Map.get(question, "options")
    allow_text = Map.get(question, "allow_text")

    String.trim(prompt) != "" and valid_options?(options) and valid_allow_text?(allow_text) and
      answerable?(options, allow_text)
  end

  defp valid_question?(_question), do: false

  defp valid_options?(nil), do: true
  defp valid_options?(options) when is_list(options), do: Enum.all?(options, &is_binary/1)
  defp valid_options?(_options), do: false

  defp valid_allow_text?(nil), do: true
  defp valid_allow_text?(allow_text), do: is_boolean(allow_text)

  # A question with text disabled must have at least one option to pick.
  defp answerable?(options, false), do: is_list(options) and options != []
  defp answerable?(_options, _allow_text), do: true
end
