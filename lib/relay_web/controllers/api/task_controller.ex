defmodule RelayWeb.Api.TaskController do
  @moduledoc """
  A card's tasks as addressable objects (RE355): list, show, bulk-add, update and delete one
  `sub_tasks` row by id, board-scoped through the card ref. Every write goes through the
  per-task `Relay.Cards` functions — never `set_sub_tasks/2`'s full replace — so other rows' ids,
  and the `node_executions.sub_task_id` history bound to them, survive. `done` is not writable
  here: `PATCH /api/cards/:ref/sub-tasks/:id` owns it.
  """
  use RelayWeb, :controller

  alias Relay.Cards
  alias RelayWeb.Api.Params

  action_fallback RelayWeb.Api.FallbackController

  @task_fields ~w(title body)

  def index(conn, %{"ref" => ref}) do
    with {:ok, card} <- fetch_card(conn, ref) do
      render(conn, :index, tasks: Cards.list_tasks(card))
    end
  end

  def show(conn, %{"ref" => ref, "id" => id}) do
    with {:ok, card} <- fetch_card(conn, ref),
         {:ok, task_id} <- task_id(id),
         {:ok, task} <- Cards.get_task(card, task_id) do
      render(conn, :show, task: task)
    end
  end

  def create(conn, %{"ref" => ref} = params) do
    with {:ok, card} <- fetch_card(conn, ref),
         {:ok, attrs_list} <- task_list(params),
         {:ok, tasks} <- card |> Cards.add_tasks(attrs_list) |> unprocessable() do
      conn
      |> put_status(:created)
      |> render(:index, tasks: tasks)
    end
  end

  def update(conn, %{"ref" => ref, "id" => id} = params) do
    with {:ok, card} <- fetch_card(conn, ref),
         {:ok, task_id} <- task_id(id),
         {:ok, attrs} <- task_patch(params),
         {:ok, task} <- card |> Cards.update_task(task_id, attrs) |> unprocessable() do
      render(conn, :show, task: task)
    end
  end

  def delete(conn, %{"ref" => ref, "id" => id}) do
    with {:ok, card} <- fetch_card(conn, ref),
         {:ok, task_id} <- task_id(id),
         {:ok, task} <- Cards.delete_task(card, task_id) do
      render(conn, :summary, task: task)
    end
  end

  defp fetch_card(conn, ref) do
    case Cards.get_card_by_ref(conn.assigns.current_board, ref) do
      %Schemas.Card{} = card -> {:ok, card}
      nil -> {:error, :not_found}
    end
  end

  # A non-integer id can't name any row: 404, like the sub-tasks toggle route.
  defp task_id(id) do
    case Params.parse_int_id(id) do
      {:ok, task_id} -> {:ok, task_id}
      :error -> {:error, :not_found}
    end
  end

  defp task_list(%{"tasks" => [_ | _] = tasks}) do
    if Enum.all?(tasks, &is_map/1),
      do: {:ok, Enum.map(tasks, &Map.take(&1, @task_fields))},
      else: invalid_tasks()
  end

  defp task_list(_params), do: invalid_tasks()

  defp invalid_tasks, do: {:error, {:invalid_request, "tasks must be a non-empty list of {title, body} objects"}}

  defp task_patch(params) do
    case Map.take(params, @task_fields) do
      attrs when map_size(attrs) > 0 -> {:ok, attrs}
      _none -> {:error, {:invalid_request, "send title and/or body"}}
    end
  end

  # A bad title is 422 on the task routes; the shared bare-changeset fallback clause is 400.
  defp unprocessable({:error, %Ecto.Changeset{} = changeset}), do: {:error, {:invalid, changeset}}
  defp unprocessable(other), do: other
end
