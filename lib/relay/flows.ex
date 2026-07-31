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

  use Boundary, deps: [Relay.Repo, Schemas], exports: [Document]

  import Ecto.Query

  alias Ecto.Changeset
  alias Relay.Flows.DefaultLibrary
  alias Relay.Flows.Document
  alias Relay.Repo
  alias Schemas.Board
  alias Schemas.Flow
  alias Schemas.FlowVersion
  alias Schemas.Run
  alias Schemas.Stage

  require Logger

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

  @doc "The board's **enabled** flows in stable `key` order (the scheduler's input)."
  def list_enabled_flows(%Board{id: board_id}) do
    Repo.all(
      from f in Flow,
        where: f.board_id == ^board_id and f.enabled == true,
        order_by: f.key
    )
  end

  # The leading slash-command token of a node's `run`, e.g. "/write-plan {ref}" → "write-plan".
  @skill_token ~r/^\/([A-Za-z0-9_-]+)/

  @doc """
  What `flow`'s graph NAMES: the agents its nodes reference and the skills its agent nodes
  invoke as a leading slash command. Pure, sorted, deduped.

  Deliberately knows nothing about executors — whether any machine HAS these is
  `Relay.Runs.preflight_flow/1`'s question. `Relay.Flows` may not depend on `Relay.Runs`
  (which already depends on Flows); the reverse edge is a boundary cycle the compiler
  rejects.

  Only `type: :agent` nodes contribute a skill: a `shell`/`gate` node's `run` is a shell
  command (`mix precommit`), and parsing it as a slash command would invent requirements
  that can never be satisfied.
  """
  def node_requirements(%Flow{} = flow) do
    nodes = flow.nodes || []

    %{
      agents: nodes |> Enum.map(& &1.agent) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort(),
      skills:
        nodes
        |> Enum.filter(&(&1.type == :agent))
        |> Enum.flat_map(&skill_token(&1.run))
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp skill_token(run) when is_binary(run) do
    case Regex.run(@skill_token, run) do
      [_full, name] -> [name]
      nil -> []
    end
  end

  defp skill_token(_run), do: []

  @doc "The board's flow with `key`, or nil."
  def get_flow(%Board{id: board_id}, key) when is_binary(key) do
    Repo.get_by(Flow, board_id: board_id, key: key)
  end

  @doc "Like get_flow/2 but raises Ecto.NoResultsError when not found."
  def get_flow!(%Board{id: board_id}, key) when is_binary(key) do
    Repo.get_by!(Flow, board_id: board_id, key: key)
  end

  @doc """
  The board's flow with `key`, trigger stages preloaded — the shape
  `Relay.Flows.Document.encode/1` requires. nil when the board has no such flow.
  """
  def get_flow_with_stages(%Board{id: board_id}, key) when is_binary(key) do
    Repo.one(
      from f in Flow,
        where: f.board_id == ^board_id and f.key == ^key,
        preload: [:pulls_from_stage, :works_in_stage, :lands_on_stage]
    )
  end

  @doc """
  Creates a flow on `board` with full graph validation. `board_id` and
  `enabled` are never cast — flows are created disabled and flipped via
  `enable_flow/1`. Inserts a v1 snapshot in the same transaction — every
  flow always has a snapshot row for its current version. Returns
  `{:ok, flow} | {:error, changeset}`.
  """
  def create_flow(%Board{} = board, attrs) do
    Repo.transaction(fn -> insert_flow!(board, attrs) end)
  end

  # Non-transactional core, shared with upsert_from_document/3 so a push runs in ONE transaction.
  defp insert_flow!(%Board{} = board, attrs) do
    changeset =
      %Flow{board_id: board.id}
      |> Flow.changeset(attrs)
      |> validate_trigger_stages(board.id)

    case Repo.insert(changeset) do
      {:ok, flow} -> snapshot!(flow)
      {:error, cs} -> Repo.rollback(cs)
    end
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
  Deletes a flow, enforcing the "disable first" rule in the domain (not just the UI): an
  **enabled** flow (the scheduler's live input) returns `{:error, :flow_enabled}` and is left
  intact. A disabled flow is deleted; the DB cascade nil-s each active run's `flow_id`
  (`runs.flow_id on_delete: :nilify_all`) and removes its version snapshots
  (`flow_versions.flow_id on_delete: :delete_all`), so no manual cleanup is needed. Returns
  `{:ok, flow} | {:error, :flow_enabled} | {:error, changeset}`.
  """
  def delete_flow(%Flow{enabled: true}), do: {:error, :flow_enabled}
  def delete_flow(%Flow{} = flow), do: Repo.delete(flow)

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

  @doc """
  Whether the flow's definition (nodes, edges, isolation) differs from the
  default library's definition for its key — normalized comparison, so the
  library's dense attr maps and the embedded structs compare field-by-field.
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
          normalize(flow.nodes, Flow.Node.fields()) != normalize(default.nodes, Flow.Node.fields()) or
          normalize(flow.edges, Flow.Edge.fields()) != normalize(default.edges, Flow.Edge.fields())
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
      key: unique_key(flow.board_id, "#{flow.key}-copy"),
      isolation: flow.isolation,
      pulls_from_stage_id: flow.pulls_from_stage_id,
      works_in_stage_id: flow.works_in_stage_id,
      lands_on_stage_id: flow.lands_on_stage_id,
      nodes: Enum.map(flow.nodes, &Map.take(&1, Flow.Node.fields())),
      edges: Enum.map(flow.edges, &Map.take(&1, Flow.Edge.fields()))
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

  @doc """
  Creates or updates `key`'s flow on `board` from a canonical `Relay.Flows.Document` (RLY-241) —
  the `PUT /api/flows/:key` write path, and the reconcile engine's.

  One transaction, in order: decode → key check → resolve the trigger stage NAMES against this
  board → optional compare-and-swap on `version` → write → reconcile `enabled`. Any step failing
  rolls the whole thing back; a push must never half-apply.

  Graph validation is not reimplemented: the write routes through `create_flow/2`'s and
  `save_definition/2`'s cores, so `Schemas.Flow.changeset/2` (a start node, edge endpoints, unique
  routing, the foreach-guard rule) is enforced exactly as the Flow Editor enforces it — and
  `save_definition/2`'s "bump and snapshot only when the definition changed" is what makes
  pull → push unchanged a genuine no-op.

  `enabled` absent from the document leaves the flow's current state untouched (a new flow is
  created disabled, as `create_flow/2` guarantees); a document that doesn't mention `enabled`
  cannot silently disarm a live flow. `version` absent means last-write-wins; `version` present
  and stale is `{:error, :stale_version}` with no write. A `version` on a flow that does not exist
  is ignored — pull → someone deletes → push recreates at v1 is desirable, not a conflict.

  Returns `{:ok, :created | :updated, flow}` with the trigger stages preloaded, or one of
  `{:error, {:invalid_document, reason}}`, `{:error, :key_mismatch}`,
  `{:error, {:unknown_stages, names}}`, `{:error, :stale_version}`,
  `{:error, {:invalid, changeset}}`.
  """
  def upsert_from_document(%Board{} = board, key, doc) when is_binary(key) and is_map(doc) do
    with {:ok, attrs} <- decode_document(doc),
         :ok <- check_document_key(attrs, key) do
      result = Repo.transaction(fn -> upsert_document!(board, key, attrs) end)

      case result do
        {:ok, {tag, flow}} -> {:ok, tag, flow}
        {:error, %Changeset{} = cs} -> {:error, {:invalid, cs}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def upsert_from_document(%Board{}, key, _doc) when is_binary(key),
    do: {:error, {:invalid_document, "document must be a JSON object"}}

  defp decode_document(doc) do
    case Document.decode(doc) do
      {:ok, attrs} -> {:ok, attrs}
      {:error, reason} -> {:error, {:invalid_document, reason}}
    end
  end

  # The path is the resource; a silent rename via PUT is a footgun for the reconcile engine.
  defp check_document_key(%{key: doc_key}, key) when doc_key != key, do: {:error, :key_mismatch}
  defp check_document_key(_attrs, _key), do: :ok

  defp upsert_document!(board, key, attrs) do
    existing = get_flow(board, key)
    check_document_version!(existing, Map.get(attrs, :version))

    definition =
      attrs
      |> Map.take([:isolation, :nodes, :edges])
      |> Map.put(:key, key)
      |> Map.merge(resolve_trigger!(board, Map.get(attrs, :trigger)))

    {tag, flow} = write_document!(board, existing, definition)
    reconcile_enabled!(flow, Map.get(attrs, :enabled))

    {tag, get_flow_with_stages(board, key)}
  end

  defp check_document_version!(nil, _version), do: :ok
  defp check_document_version!(_flow, nil), do: :ok
  defp check_document_version!(%Flow{version: version}, version), do: :ok
  defp check_document_version!(_flow, _stale), do: Repo.rollback(:stale_version)

  # Names, not ids — that is what makes a document portable across boards. An explicit null is
  # allowed and resolves to nil (the flow is deliberately un-armed); a trigger absent from the
  # document leaves the flow's current wiring alone.
  defp resolve_trigger!(_board, nil), do: %{}

  defp resolve_trigger!(%Board{id: board_id}, trigger) do
    ids = Map.new(Repo.all(from s in Stage, where: s.board_id == ^board_id, select: {s.name, s.id}))

    pairs = [
      {:pulls_from_stage_id, trigger.pulls_from},
      {:works_in_stage_id, trigger.works_in},
      {:lands_on_stage_id, trigger.lands_on}
    ]

    missing = Enum.uniq(for {_field, name} <- pairs, is_binary(name), not is_map_key(ids, name), do: name)

    if missing == [] do
      Map.new(pairs, fn {field, name} -> {field, name && Map.get(ids, name)} end)
    else
      Repo.rollback({:unknown_stages, missing})
    end
  end

  defp write_document!(board, nil, definition), do: {:created, insert_flow!(board, definition)}

  defp write_document!(_board, %Flow{} = flow, definition), do: {:updated, save_and_maybe_bump(flow, definition)}

  # Route through enable_flow/1 / disable_flow/1 so the existing rules apply — trigger
  # completeness, and the one-enabled-flow-per-pulls_from-stage unique index.
  defp reconcile_enabled!(_flow, nil), do: :ok
  defp reconcile_enabled!(%Flow{enabled: enabled}, enabled), do: :ok

  defp reconcile_enabled!(flow, true) do
    case enable_flow(flow) do
      {:ok, _flow} -> :ok
      {:error, cs} -> Repo.rollback(cs)
    end
  end

  defp reconcile_enabled!(flow, false) do
    case disable_flow(flow) do
      {:ok, _flow} -> :ok
      {:error, cs} -> Repo.rollback(cs)
    end
  end

  @doc "The immutable snapshot for `flow` at version `n`, or nil."
  def get_version(%Flow{id: flow_id}, n) when is_integer(n) do
    Repo.get_by(FlowVersion, flow_id: flow_id, version: n)
  end

  @doc """
  Count of cards currently mid-run on this flow — runs whose status is active
  (`Schemas.Run.active_statuses/0`, i.e. running or parked). Feeds both the flow-editor save
  note and the delete-confirm warning, so the "cards mid-run" number is defined once here.
  """
  def mid_run_count(%Flow{id: flow_id}) do
    Repo.aggregate(
      from(r in Run, where: r.flow_id == ^flow_id and r.status in ^Run.active_statuses()),
      :count
    )
  end

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

  @doc """
  The first key of the form `base`, `base-2`, `base-3`, … not already taken on `board`.
  Backs both Duplicate's `-copy` suffix and the create form's prefilled default key.
  """
  def unique_key(%Board{id: board_id}, base) when is_binary(base), do: unique_key(board_id, base)

  def unique_key(board_id, base) when is_integer(board_id) and is_binary(base) do
    taken = MapSet.new(Repo.all(from f in Flow, where: f.board_id == ^board_id, select: f.key))

    if MapSet.member?(taken, base) do
      Enum.find(Stream.map(2..10_000, &"#{base}-#{&1}"), &(not MapSet.member?(taken, &1)))
    else
      base
    end
  end

  @doc """
  Re-syncs every board's library-key flows to the CURRENT default library, so a library edit
  (e.g. RLY-192's new sync nodes) reaches boards that already exist — not just newly created ones.
  Called at deploy from `Relay.Release.migrate/0` and by `mix relay.flows.sync_defaults`.

  A flow is upgraded only when it is **library-managed**, detected as `version == 1`: seeding
  creates flows at v1 and the only path that bumps a flow past 1 is a human editing it in
  Settings › Flows (`save_definition/2`). So `version > 1` means hand-edited — its edits are
  preserved (skipped). A v1 flow already identical to the library is left untouched (unchanged).

  Crucially the upgrade KEEPS the flow at version 1 (it does not route through `save_definition/2`,
  which would bump to v2) so a *future* library edit still finds it at v1 and upgrades it again;
  the v1 snapshot is refreshed in place to preserve the per-version snapshot invariant. Runs read
  the live flow row (RLY-152), so overwriting it is what reaches new runs.

  Returns and logs `%{upgraded: keys, skipped: keys, unchanged: keys}` where each key is a
  `{board_id, flow_key}` tuple.
  """
  def sync_defaults! do
    library = Map.new(DefaultLibrary.all(), &{&1.key, &1})
    flows = Repo.all(from f in Flow, where: f.key in ^Map.keys(library))

    summary =
      Enum.reduce(flows, %{upgraded: [], skipped: [], unchanged: []}, fn flow, acc ->
        key = {flow.board_id, flow.key}
        default = Map.fetch!(library, flow.key)

        cond do
          flow.version > 1 ->
            Map.update!(acc, :skipped, &[key | &1])

          not customized?(flow) ->
            Map.update!(acc, :unchanged, &[key | &1])

          true ->
            sync_flow_to_default!(flow, default)
            Map.update!(acc, :upgraded, &[key | &1])
        end
      end)

    Logger.info(
      "Relay.Flows.sync_defaults!: upgraded=#{length(summary.upgraded)} " <>
        "skipped=#{length(summary.skipped)} unchanged=#{length(summary.unchanged)}"
    )

    summary
  end

  defp default_for(key), do: Enum.find(DefaultLibrary.all(), &(&1.key == key))

  # Embedded structs and the library's plain attr maps normalize to the same shape: every
  # field present. Both sides are already dense — a struct always carries every field, and
  # `Relay.Flows.Document.decode/1` fills every field the JSON omits with the schema default
  # (pinned by default_library_test's denseness assertion), which is exactly what lets this
  # compare field-by-field with no per-field default handling.
  defp normalize(items, fields), do: Enum.map(items || [], &normalize_one(&1, fields))

  defp normalize_one(item, fields), do: Map.new(fields, &{&1, Map.get(item, &1)})

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
      nodes: Enum.map(flow.nodes, &Map.take(&1, Flow.Node.fields())),
      edges: Enum.map(flow.edges, &Map.take(&1, Flow.Edge.fields()))
    })
    |> Repo.insert!()

    flow
  end

  # Overwrite `flow`'s definition with the library `default`, KEEPING version at 1, and refresh the
  # v1 snapshot so it matches. Deliberately NOT `save_definition/2`: that bumps the version, which
  # would make the next library sync skip this flow (version > 1). Triggers/enabled are untouched;
  # runs read the live row (RLY-152), so this row overwrite is what reaches new runs.
  defp sync_flow_to_default!(flow, default) do
    attrs = %{
      isolation: default.isolation,
      nodes: Enum.map(default.nodes, &Map.take(&1, Flow.Node.fields())),
      edges: Enum.map(default.edges, &Map.take(&1, Flow.Edge.fields()))
    }

    Repo.transaction(fn ->
      updated = flow |> Flow.changeset(attrs) |> Repo.update!()
      Repo.delete_all(from v in FlowVersion, where: v.flow_id == ^flow.id and v.version == 1)
      snapshot!(updated)
    end)

    :ok
  end

  defp definition_changed?(%Flow{} = before, %Flow{} = now) do
    before.isolation != now.isolation or
      normalize(before.nodes, Flow.Node.fields()) != normalize(now.nodes, Flow.Node.fields()) or
      normalize(before.edges, Flow.Edge.fields()) != normalize(now.edges, Flow.Edge.fields())
  end

  defp diff_nodes(flow, default) do
    cur = Map.new(flow.nodes, &{&1.key, &1})

    def_ = Map.new(default.nodes, &{&1.key, normalize_one(&1, Flow.Node.fields())})

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
    for f <- Flow.Node.fields(), Map.get(node, f) != Map.get(default_map, f), do: f
  end

  defp diff_edges(flow, default) do
    cur = MapSet.new(flow.edges, &{&1.from, &1.to, &1.on})
    def_ = MapSet.new(default.edges, &{&1.from, &1.to, Map.get(&1, :on)})

    %{
      added: Enum.sort(MapSet.to_list(MapSet.difference(cur, def_))),
      removed: Enum.sort(MapSet.to_list(MapSet.difference(def_, cur)))
    }
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
