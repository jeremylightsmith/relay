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
  alias Schemas.FlowVersion
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
  `enable_flow/1`. Inserts a v1 snapshot in the same transaction — every
  flow always has a snapshot row for its current version. Returns
  `{:ok, flow} | {:error, changeset}`.
  """
  def create_flow(%Board{} = board, attrs) do
    changeset =
      %Flow{board_id: board.id}
      |> Flow.changeset(attrs)
      |> validate_trigger_stages(board.id)

    Repo.transaction(fn ->
      case Repo.insert(changeset) do
        {:ok, flow} -> snapshot!(flow)
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  @doc """
  Updates a flow's definition with the same validation as `create_flow/2`. Also guards the
  one-enabled-per-pulls-from-stage rule (mirrors `enable_flow/1`) — an already-enabled flow can
  change its `pulls_from_stage_id` right into another enabled flow's, and the partial unique
  index would otherwise raise instead of returning `{:error, changeset}`.
  """
  def update_flow(%Flow{} = flow, attrs) do
    flow
    |> Flow.changeset(attrs)
    |> validate_trigger_stages(flow.board_id)
    |> Changeset.unique_constraint(:pulls_from_stage_id,
      name: :flows_one_enabled_per_pulls_from_index,
      message: "another enabled flow already pulls from this stage"
    )
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
      |> snapshot!()
    end

    :ok
  end

  @node_fields [:key, :type, :run, :model, :effort, :max_retries, :timeout_minutes]
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
  `-copy-3`, … until unique). Inserts a v1 snapshot in the same transaction.
  Returns `{:ok, flow} | {:error, changeset}`.
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

    Repo.transaction(fn ->
      case Repo.insert(Flow.changeset(%Flow{board_id: flow.board_id}, attrs)) do
        {:ok, copy} -> snapshot!(copy)
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  @doc """
  The editor's save path. Validates the working copy like `update_flow/2`. When the
  **definition** (nodes, edges, isolation) changed, bumps `version` to n+1 and writes a new
  immutable snapshot; a trigger-only change saves with no bump (triggers are per-board wiring,
  not part of the versioned definition). Runs entirely in one transaction.
  """
  def save_definition(%Flow{} = flow, attrs) do
    fn -> save_and_maybe_bump(flow, attrs) end
    |> Repo.transaction()
    |> preload_saved()
  end

  @doc "The immutable snapshot for `flow` at version `n`, or nil."
  def get_version(%Flow{id: flow_id}, n) when is_integer(n) do
    Repo.get_by(FlowVersion, flow_id: flow_id, version: n)
  end

  @doc """
  Count of cards currently mid-run on this flow. Returns 0 until the Runs schema (RLY-132)
  exists — the save modal omits the mid-run note when 0. RLY-132 makes this real.
  """
  def mid_run_count(%Flow{}), do: 0

  @doc """
  Structural diff of a customized default flow against its shipped default, or nil for a
  non-default key. Node keys are grouped added/removed/changed (changed lists the differing
  fields); edges are `{from, to, on}` tuples grouped added/removed.
  """
  def diff_from_default(%Flow{} = flow) do
    case default_for(flow.key) do
      nil -> nil
      default -> %{nodes: diff_nodes(flow, default), edges: diff_edges(flow, default)}
    end
  end

  @doc """
  Replaces the flow's nodes, edges, and isolation with the default library
  definition for its key. Triggers and `enabled` are untouched, so a reset
  can never trip the one-enabled-per-pulls-from rule. Routes through
  `save_definition/2`, so a reset bumps the version and snapshots like any
  save. Returns `{:error, :not_a_default}` for a non-library key.
  """
  def reset_to_default(%Flow{} = flow) do
    case default_for(flow.key) do
      nil -> {:error, :not_a_default}
      default -> save_definition(flow, Map.take(default, [:isolation, :nodes, :edges]))
    end
  end

  defp default_for(key), do: Enum.find(DefaultLibrary.all(), &(&1.key == key))

  # Embedded structs and the library's plain attr maps normalize to the same
  # shape: every field present, nil when unset.
  defp normalize(items, fields) do
    Enum.map(items || [], fn item -> Map.new(fields, &{&1, Map.get(item, &1)}) end)
  end

  defp save_and_maybe_bump(flow, attrs) do
    case update_flow(flow, attrs) do
      {:error, cs} -> Repo.rollback(cs)
      {:ok, updated} -> bump_if_changed(flow, updated)
    end
  end

  defp bump_if_changed(flow, updated) do
    if definition_changed?(flow, updated) do
      updated
      |> Changeset.change(version: flow.version + 1)
      |> Repo.update!()
      |> snapshot!()
    else
      updated
    end
  end

  defp preload_saved({:ok, flow}) do
    {:ok, Repo.preload(flow, [:pulls_from_stage, :works_in_stage, :lands_on_stage])}
  end

  defp preload_saved(other), do: other

  defp snapshot!(%Flow{} = flow) do
    %FlowVersion{}
    |> FlowVersion.snapshot_changeset(%{
      flow_id: flow.id,
      version: flow.version,
      isolation: flow.isolation,
      nodes: Enum.map(flow.nodes, &Map.take(&1, @node_fields)),
      edges: Enum.map(flow.edges, &Map.take(&1, @edge_fields))
    })
    |> Repo.insert!()

    flow
  end

  defp definition_changed?(%Flow{} = before, %Flow{} = now) do
    before.isolation != now.isolation or
      normalize(before.nodes, @node_fields) != normalize(now.nodes, @node_fields) or
      normalize(before.edges, @edge_fields) != normalize(now.edges, @edge_fields)
  end

  defp diff_nodes(flow, default) do
    cur = Map.new(flow.nodes, &{&1.key, &1})
    def_ = Map.new(default.nodes, &{&1.key, Map.new(@node_fields, fn f -> {f, Map.get(&1, f)} end)})
    cur_keys = MapSet.new(Map.keys(cur))
    def_keys = MapSet.new(Map.keys(def_))

    changed =
      for key <- MapSet.intersection(cur_keys, def_keys),
          fields = changed_fields(Map.fetch!(cur, key), Map.fetch!(def_, key)),
          fields != [],
          do: %{key: key, fields: fields}

    %{
      added: Enum.sort(MapSet.to_list(MapSet.difference(cur_keys, def_keys))),
      removed: Enum.sort(MapSet.to_list(MapSet.difference(def_keys, cur_keys))),
      changed: Enum.sort_by(changed, & &1.key)
    }
  end

  defp changed_fields(node, default_map) do
    for f <- @node_fields, Map.get(node, f) != Map.get(default_map, f), do: f
  end

  defp diff_edges(flow, default) do
    cur = MapSet.new(flow.edges, &{&1.from, &1.to, &1.on})
    def_ = MapSet.new(default.edges, &{&1.from, &1.to, Map.get(&1, :on)})

    %{
      added: Enum.sort(MapSet.to_list(MapSet.difference(cur, def_))),
      removed: Enum.sort(MapSet.to_list(MapSet.difference(def_, cur)))
    }
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
