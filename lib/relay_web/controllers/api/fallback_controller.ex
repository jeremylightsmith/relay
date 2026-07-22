defmodule RelayWeb.Api.FallbackController do
  @moduledoc "Maps context error tuples to JSON error responses."
  use RelayWeb, :controller

  alias RelayWeb.Api.ErrorJSON

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: "not_found", message: "Not found")
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: "invalid", message: changeset_message(changeset))
  end

  def call(conn, {:error, :invalid_request}) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: "invalid", message: "Invalid request")
  end

  def call(conn, {:error, :not_in_review}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: "not_in_review", message: "This card is not in a review stage")
  end

  def call(conn, {:error, :not_needs_input}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: "not_needs_input", message: "This card is not waiting on an answer")
  end

  def call(conn, {:error, :ambiguous_ref}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ErrorJSON)
    |> render(:error,
      code: "ambiguous_ref",
      message: "That ref matches cards on more than one of your boards — pass board: <slug>"
    )
  end

  def call(conn, {:error, :missing_note}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: "missing_note", message: "note is required")
  end

  def call(conn, {:error, :missing_title}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: "missing_title", message: "title is required")
  end

  def call(conn, {:error, :invalid_stage}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: "invalid_stage", message: "stage must be one of the board's top-level stages")
  end

  def call(conn, {:error, :invalid_target}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: "invalid_target", message: "target must be a main-lane stage before this card")
  end

  def call(conn, {:error, :conflict}) do
    conn
    |> put_status(:conflict)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: "conflict", message: "This job is no longer held by your claim")
  end

  def call(conn, {:error, :would_strand_run}) do
    conn
    |> put_status(:conflict)
    |> put_view(json: ErrorJSON)
    |> render(:error,
      code: "would_strand_run",
      message: "This card has a live run — cancel the run before moving it out of its work lane"
    )
  end

  def call(conn, {:error, :unknown_outcome}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ErrorJSON)
    |> render(:error,
      code: "unknown_outcome",
      message: "outcome must be one of: succeeded, failed, partial, needs_input"
    )
  end

  def call(conn, {:error, :invalid_executor}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: "invalid_executor", message: "executor must be an object")
  end

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end
end
