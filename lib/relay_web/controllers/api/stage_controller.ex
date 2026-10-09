defmodule RelayWeb.Api.StageController do
  @moduledoc """
  A board's stages over REST (RE384): list, create (optionally anchored), configure, place,
  toggle Review/Done substages, and delete — board-scoped through the API key, any board key.
  Every write goes through the `Relay.Boards` guard rails (`Relay.Cards.update_stage/2` for
  configuration, so a type change re-snaps resident cards); the refusals reach the client via
  `RelayWeb.Api.FallbackController` with `Boards.stage_refusal_message/1`'s sentence.

  `ai_enabled` is read-only (RE409): every render derives it from `Relay.Flows.ai_stage_ids/1`,
  and a create/update body naming it — any value — is refused 422 before anything is written.
  """
  use RelayWeb, :controller

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Flows
  alias RelayWeb.Api.Params

  action_fallback RelayWeb.Api.FallbackController

  @create_fields ~w(name category type description wip_limit collapsed_by_default)a
  @update_fields ~w(name description type wip_limit collapsed_by_default reject_to_stage_id)

  @ai_enabled_refusal "ai_enabled is derived from flows — put a flow on this stage instead"

  def index(conn, _params) do
    board = conn.assigns.current_board
    render(conn, :index, stages: Boards.list_stages(board), ai_stage_ids: Flows.ai_stage_ids(board))
  end

  def create(conn, params) do
    board = conn.assigns.current_board

    with :ok <- refuse_ai_enabled(params),
         {:ok, anchor} <- create_anchor(board, params),
         attrs = params |> whitelist(@create_fields) |> Map.merge(anchor),
         {:ok, stage} <- board |> Boards.create_stage(attrs) |> unprocessable() do
      conn
      |> put_status(:created)
      |> render_stage(stage)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- refuse_ai_enabled(params),
         {:ok, stage} <- fetch_stage(conn, id),
         {:ok, attrs} <- stage_patch(params),
         {:ok, stage} <- stage |> Cards.update_stage(attrs) |> unprocessable() do
      render_stage(conn, stage)
    end
  end

  def place(conn, %{"id" => id} = params) do
    board = conn.assigns.current_board

    with {:ok, stage} <- fetch_stage(conn, id),
         {:ok, {side, anchor_id}} <- one_anchor(params),
         {:ok, anchor} <- fetch_anchor(board, anchor_id),
         {:ok, stage} <- Boards.place_stage(stage, [{side, anchor}]) do
      render_stage(conn, stage)
    end
  end

  def enable_lane(conn, %{"id" => id, "lane" => lane}) do
    with {:ok, stage} <- fetch_stage(conn, id),
         {:ok, lane} <- parse_lane(lane),
         {:ok, substage} <- Boards.enable_lane(stage, lane) do
      render_stage(conn, substage)
    end
  end

  def disable_lane(conn, %{"id" => id, "lane" => lane}) do
    with {:ok, stage} <- fetch_stage(conn, id),
         {:ok, lane} <- parse_lane(lane),
         :ok <- main_stage(stage),
         {:ok, result} <- Boards.disable_lane(stage, lane) do
      render(conn, :lane, lane: Atom.to_string(lane), disabled: result == :disabled)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, stage} <- fetch_stage(conn, id),
         {:ok, deleted} <- Boards.delete_stage(stage) do
      render_stage(conn, deleted)
    end
  end

  defp render_stage(conn, stage),
    do: render(conn, :show, stage: stage, ai_stage_ids: Flows.ai_stage_ids(conn.assigns.current_board))

  # The key, not its value: `"ai_enabled": false` or `null` is refused too, so an old caller
  # never mistakes a silent no-op for a write.
  defp refuse_ai_enabled(%{"ai_enabled" => _}), do: {:error, {:invalid_request, @ai_enabled_refusal}}
  defp refuse_ai_enabled(_params), do: :ok

  # An unknown, foreign or non-integer path id can't name one of this board's stages: 404.
  defp fetch_stage(conn, id) do
    with {:ok, stage_id} <- Params.parse_int_id(id),
         %Schemas.Stage{} = stage <- Boards.get_stage(conn.assigns.current_board, stage_id) do
      {:ok, stage}
    else
      _missing -> {:error, :not_found}
    end
  end

  # An anchor that doesn't name one of this board's stages is a bad request field, not a missing
  # resource: 422 `invalid_anchor`. Whether it is a MAIN stage is the domain's call.
  defp fetch_anchor(board, id) do
    with {:ok, stage_id} <- parse_anchor_id(id),
         %Schemas.Stage{} = anchor <- Boards.get_stage(board, stage_id) do
      {:ok, anchor}
    else
      _missing -> {:error, :invalid_anchor}
    end
  end

  defp parse_anchor_id(id) when is_integer(id) or is_binary(id), do: Params.parse_int_id(id)
  defp parse_anchor_id(_id), do: :error

  defp create_anchor(board, params) do
    case anchors(params) do
      [] -> {:ok, %{}}
      [{side, id}] -> with {:ok, anchor} <- fetch_anchor(board, id), do: {:ok, %{side => anchor}}
      _both -> {:error, {:invalid_request, "send before or after, not both"}}
    end
  end

  defp one_anchor(params) do
    case anchors(params) do
      [anchor] -> {:ok, anchor}
      _none_or_both -> {:error, {:invalid_request, "send exactly one of before or after"}}
    end
  end

  defp anchors(params) do
    for {key, side} <- [{"before", :before}, {"after", :after}], id = params[key], not is_nil(id), do: {side, id}
  end

  # `Boards.create_stage/2` takes atom keys: a fixed atom whitelist picks the string params, so
  # no request value ever becomes an atom.
  defp whitelist(params, fields) do
    for field <- fields,
        Map.has_key?(params, Atom.to_string(field)),
        into: %{},
        do: {field, params[Atom.to_string(field)]}
  end

  defp stage_patch(params) do
    case Map.take(params, @update_fields) do
      attrs when map_size(attrs) > 0 -> {:ok, attrs}
      _none -> {:error, {:invalid_request, "send at least one of: #{Enum.join(@update_fields, ", ")}"}}
    end
  end

  defp parse_lane(lane) do
    case Enum.find(Schemas.Stage.sublane_types(), &(Atom.to_string(&1) == lane)) do
      nil -> {:error, {:invalid_request, "lane must be one of: #{lane_names()}"}}
      lane -> {:ok, lane}
    end
  end

  defp lane_names, do: Enum.map_join(Schemas.Stage.sublane_types(), ", ", &Atom.to_string/1)

  # `Boards.disable_lane/2` on a substage would find no lane and answer "not enabled" — a
  # misleading success; refuse it like enable does.
  defp main_stage(%Schemas.Stage{parent_id: nil}), do: :ok
  defp main_stage(%Schemas.Stage{}), do: {:error, :not_a_main_stage}

  # A bad stage is 422 here; the shared bare-changeset fallback clause is 400.
  defp unprocessable({:error, %Ecto.Changeset{} = changeset}), do: {:error, {:invalid, changeset}}
  defp unprocessable(other), do: other
end
