defmodule Relay.Flows do
  @moduledoc """
  The Flows context (ADR 0006 / RLY-131): workflow definitions as
  declarative graph data owned by Relay. A flow is a per-board row — a
  trigger (three stage ids), an isolation requirement the executor maps
  (`:shared_clean` / `:exclusive`), and an embedded node/edge graph.
  Nothing here executes; the engine arrives with the Runs card (02).

  Graph-shape validation lives on `Schemas.Flow.changeset/2`; validation
  that needs the database — trigger stages belong to the flow's board, at
  most one enabled flow per pulls-from stage — lives here and still returns
  `{:error, changeset}`.
  """

  use Boundary, deps: [Relay.Repo, Schemas]

  import Ecto.Query

  alias Ecto.Changeset
  alias Relay.Repo
  alias Schemas.Board
  alias Schemas.Flow
  alias Schemas.Stage

  @trigger_fields [:pulls_from_stage_id, :works_in_stage_id, :lands_on_stage_id]

  @doc "The board's flows in stable `key` order, trigger stages preloaded."
  def list_flows(%Board{id: board_id}) do
    Repo.all(
      from f in Flow,
        where: f.board_id == ^board_id,
        order_by: f.key,
        preload: [:pulls_from_stage, :works_in_stage, :lands_on_stage]
    )
  end

  @doc "The board's flow with `key`, or nil."
  def get_flow(%Board{id: board_id}, key) when is_binary(key) do
    Repo.get_by(Flow, board_id: board_id, key: key)
  end

  @doc "Like get_flow/2 but raises Ecto.NoResultsError when not found."
  def get_flow!(%Board{id: board_id}, key) when is_binary(key) do
    Repo.get_by!(Flow, board_id: board_id, key: key)
  end

  @doc """
  Creates a flow on `board` with full graph validation. `board_id` and
  `enabled` are never cast — flows are created disabled and flipped via
  `enable_flow/1`. Returns `{:ok, flow} | {:error, changeset}`.
  """
  def create_flow(%Board{} = board, attrs) do
    %Flow{board_id: board.id}
    |> Flow.changeset(attrs)
    |> validate_trigger_stages(board.id)
    |> Repo.insert()
  end

  @doc "Updates a flow's definition with the same validation as `create_flow/2`."
  def update_flow(%Flow{} = flow, attrs) do
    flow
    |> Flow.changeset(attrs)
    |> validate_trigger_stages(flow.board_id)
    |> Repo.update()
  end

  @doc """
  Enables a flow. Requires all three trigger stage ids set and no other
  enabled flow pulling from the same stage — the partial unique index backs
  the latter, so two racing enables can't both win. Returns
  `{:ok, flow} | {:error, changeset}`.
  """
  def enable_flow(%Flow{} = flow) do
    flow
    |> Changeset.change(enabled: true)
    |> validate_trigger_completeness()
    |> Changeset.unique_constraint(:pulls_from_stage_id,
      name: :flows_one_enabled_per_pulls_from_index,
      message: "another enabled flow already pulls from this stage"
    )
    |> Repo.update()
  end

  @doc "Disables a flow."
  def disable_flow(%Flow{} = flow) do
    flow
    |> Changeset.change(enabled: false)
    |> Repo.update()
  end

  defp validate_trigger_completeness(changeset) do
    Enum.reduce(@trigger_fields, changeset, fn field, cs ->
      if Changeset.get_field(cs, field) do
        cs
      else
        Changeset.add_error(cs, field, "must be set before the flow can be enabled")
      end
    end)
  end

  defp validate_trigger_stages(changeset, board_id) do
    board_stage_ids = MapSet.new(Repo.all(from s in Stage, where: s.board_id == ^board_id, select: s.id))

    Enum.reduce(@trigger_fields, changeset, fn field, cs ->
      id = Changeset.get_field(cs, field)

      if is_nil(id) or MapSet.member?(board_stage_ids, id) do
        cs
      else
        Changeset.add_error(cs, field, "stage is not on this board")
      end
    end)
  end
end
