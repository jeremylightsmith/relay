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
  alias Relay.Flows.DefaultLibrary
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

  @doc """
  Idempotently seeds the default library onto `board`: inserts each default
  flow whose `key` the board lacks and never touches existing rows, so edits
  survive re-seeding. The authored trigger stage *names* are resolved
  against the board's stages at seed time; an unresolvable name seeds as nil
  (such a flow can't be enabled until its trigger is set — can't happen on
  boards seeded by `Relay.Boards.create_board/2`, but keeps the function
  total for arbitrary boards).
  """
  def seed_default_flows!(%Board{id: board_id} = board) do
    existing = MapSet.new(Repo.all(from f in Flow, where: f.board_id == ^board_id, select: f.key))
    stage_ids = Map.new(Repo.all(from s in Stage, where: s.board_id == ^board_id, select: {s.name, s.id}))

    for %{trigger: trigger} = default <- DefaultLibrary.all(),
        not MapSet.member?(existing, default.key) do
      attrs =
        default
        |> Map.delete(:trigger)
        |> Map.merge(%{
          pulls_from_stage_id: stage_ids[trigger.pulls_from],
          works_in_stage_id: stage_ids[trigger.works_in],
          lands_on_stage_id: stage_ids[trigger.lands_on]
        })

      %Flow{board_id: board.id}
      |> Flow.changeset(attrs)
      |> Repo.insert!()
    end

    :ok
  end

  @node_fields [:key, :type, :run, :model, :effort, :max_retries]
  @edge_fields [:from, :to, :on, :max_loops]

  @doc """
  Whether the flow's definition (nodes, edges, isolation) differs from the
  default library's definition for its key — normalized comparison, so the
  library's sparse attr maps and the embedded structs compare field-by-field.
  A flow whose key isn't a library key at all (e.g. a duplicate) is always
  customized. Trigger wiring never counts: triggers are per-board and a
  stage rename must not flag a flow.
  """
  def customized?(%Flow{} = flow) do
    case default_for(flow.key) do
      nil ->
        true

      default ->
        flow.isolation != default.isolation or
          normalize(flow.nodes, @node_fields) != normalize(default.nodes, @node_fields) or
          normalize(flow.edges, @edge_fields) != normalize(default.edges, @edge_fields)
    end
  end

  @doc "Whether `key` names one of the shipped default library flows."
  def default_key?(key) when is_binary(key), do: default_for(key) != nil

  @doc """
  Creates a disabled copy of `flow` on the same board — same nodes, edges,
  isolation, and trigger stages — under key `"<key>-copy"` (then `-copy-2`,
  `-copy-3`, … until unique). Returns `{:ok, flow} | {:error, changeset}`.
  """
  def duplicate_flow(%Flow{} = flow) do
    attrs = %{
      key: unique_copy_key(flow),
      isolation: flow.isolation,
      pulls_from_stage_id: flow.pulls_from_stage_id,
      works_in_stage_id: flow.works_in_stage_id,
      lands_on_stage_id: flow.lands_on_stage_id,
      nodes: Enum.map(flow.nodes, &Map.take(&1, @node_fields)),
      edges: Enum.map(flow.edges, &Map.take(&1, @edge_fields))
    }

    %Flow{board_id: flow.board_id}
    |> Flow.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Replaces the flow's nodes, edges, and isolation with the default library
  definition for its key. Triggers and `enabled` are untouched, so a reset
  can never trip the one-enabled-per-pulls-from rule. Returns
  `{:error, :not_a_default}` for a non-library key. No version history yet
  (RLY-152).
  """
  def reset_to_default(%Flow{} = flow) do
    case default_for(flow.key) do
      nil -> {:error, :not_a_default}
      default -> update_flow(flow, Map.take(default, [:isolation, :nodes, :edges]))
    end
  end

  defp default_for(key), do: Enum.find(DefaultLibrary.all(), &(&1.key == key))

  # Embedded structs and the library's plain attr maps normalize to the same
  # shape: every field present, nil when unset.
  defp normalize(items, fields) do
    Enum.map(items || [], fn item -> Map.new(fields, &{&1, Map.get(item, &1)}) end)
  end

  defp unique_copy_key(%Flow{board_id: board_id, key: key}) do
    taken = MapSet.new(Repo.all(from f in Flow, where: f.board_id == ^board_id, select: f.key))
    base = "#{key}-copy"

    if MapSet.member?(taken, base) do
      Enum.find(Stream.map(2..10_000, &"#{base}-#{&1}"), &(not MapSet.member?(taken, &1)))
    else
      base
    end
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
