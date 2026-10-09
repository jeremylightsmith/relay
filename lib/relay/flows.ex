defmodule Relay.Flows do
  @moduledoc """
  The Flows context (ADR 0006 / RLY-131): workflow definitions as
  declarative graph data owned by Relay. A flow is a per-board row — the ONE
  main work/planning stage it belongs to (RE429), an isolation requirement the
  runner maps (`:shared_clean` / `:exclusive`), and an embedded node/edge graph.
  Where it picks cards up and drops them off is worked out from board order by
  `neighbours/2`, never stored.

  Graph-shape validation lives on `Schemas.Flow.changeset/2`; validation
  that needs the database — the stage is on the flow's board, a main work
  stage, and holds no other flow — lives here and still returns
  `{:error, changeset}`.
  """

  use Boundary, deps: [Relay.Repo, Schemas], exports: [Document, Shape]

  import Ecto.Query

  alias Ecto.Changeset
  alias Relay.Flows.DefaultLibrary
  alias Relay.Flows.Document
  alias Relay.Flows.Shape
  alias Relay.Repo
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Flow
  alias Schemas.FlowVersion
  alias Schemas.Run
  alias Schemas.Stage

  require Logger

  @doc """
  The board's flows in stable `key` order, `:stage` preloaded and the virtual `pulls_from_stage` /
  `lands_on_stage` worked out from the board's CURRENT order (`neighbours/2`), plus each flow's
  `problem` (`Relay.Flows.Shape`, RE430) — `nil` on a healthy shape.
  """
  def list_flows(%Board{id: board_id}) do
    from(f in Flow, where: f.board_id == ^board_id, order_by: f.key, preload: :stage)
    |> Repo.all()
    |> with_neighbours(board_id)
  end

  @doc "The board's **enabled** flows in stable `key` order (the scheduler's input)."
  def list_enabled_flows(%Board{id: board_id}), do: Repo.all(enabled_flows_query(board_id))

  @doc """
  EVERY flow of the board — enabled and disabled — as `%{key, stage_id, isolation, enabled}` in
  `key` order: the one lean read the scheduler snapshot builds on (RE402). One query. The
  scheduler keeps only the `enabled` ones as its dispatch `flows` and adds each one's derived
  `pulls_from_stage_id` itself, from the ordered stages it already holds; it hands ALL of them to
  `Relay.Flows.Shape.problems/2`, so a disabled flow is still named as an upstream (RE430).
  """
  @spec list_flow_snapshots(integer()) :: [
          %{key: String.t(), stage_id: integer(), isolation: :shared_clean | :exclusive, enabled: boolean()}
        ]
  def list_flow_snapshots(board_id) do
    Repo.all(
      from(f in Flow,
        where: f.board_id == ^board_id,
        order_by: f.key,
        select: %{key: f.key, stage_id: f.stage_id, isolation: f.isolation, enabled: f.enabled}
      )
    )
  end

  # The ONE "enabled flows of a board" predicate.
  defp enabled_flows_query(board_id) do
    from f in Flow, where: f.board_id == ^board_id and f.enabled == true, order_by: f.key
  end

  # The leading slash-command token of a node's `run`, e.g. "/write-plan {ref}" → "write-plan".
  @skill_token ~r/^\/([A-Za-z0-9_-]+)/

  @doc """
  What `flow`'s graph NAMES: the agents its nodes reference and the skills its agent nodes
  invoke as a leading slash command. Pure, sorted, deduped.

  Deliberately knows nothing about runners — whether any machine HAS these is
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
  The enabled flow on `card`'s CURRENT stage, or nil — "which flow owns this card where it now
  sits", answered from the card's stage alone rather than from any run FK. A stage holds at most
  one flow (RE429), so the answer is unique.

  The ONE place that lookup lives (AGENTS.md): rejection re-entry (`Relay.Runs.Listener`) and
  retry's re-adoption of a replaced flow (`Relay.Runs.retry_run/2`, RE297) both ask it, and a
  second copy could answer differently about the same card.
  """
  def working_flow(%Card{board_id: board_id, stage_id: stage_id}) do
    Repo.one(from f in Flow, where: f.board_id == ^board_id and f.stage_id == ^stage_id and f.enabled)
  end

  @doc "The flow on `stage` (enabled or not), or nil — a stage holds at most one (RE429)."
  @spec stage_flow(Stage.t() | integer()) :: Flow.t() | nil
  def stage_flow(%Stage{id: stage_id}), do: stage_flow(stage_id)
  def stage_flow(stage_id) when is_integer(stage_id), do: Repo.get_by(Flow, stage_id: stage_id)

  @doc """
  The flow each stage of the board is AI-enabled by (RE409): one entry per stage that holds a
  flow — enabled **or** disabled — mapped to `%{key, enabled, version}`. A stage holds at most
  one flow (RE429), so there is nothing to break a tie on. `version` feeds the stage-delete
  confirm ("This also deletes flow `ship` (v3).").

  The ONE source of the "AI-enabled stage" fact (AGENTS.md): `ai_stage_ids/1` is built on it
  and `ai_stage?/1` asks the same `stage_id` question for one stage. Deliberately type-blind —
  each reader keeps its own work/planning guard.
  """
  @spec stage_flows(Board.t() | integer()) :: %{
          integer() => %{key: String.t(), enabled: boolean(), version: pos_integer()}
        }
  def stage_flows(%Board{id: board_id}), do: stage_flows(board_id)

  def stage_flows(board_id) when is_integer(board_id) do
    from(f in Flow,
      where: f.board_id == ^board_id,
      select: {f.stage_id, %{key: f.key, enabled: f.enabled, version: f.version}}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "The ids of the board's AI-enabled stages — exactly the keys of `stage_flows/1`."
  @spec ai_stage_ids(Board.t() | integer()) :: MapSet.t(integer())
  def ai_stage_ids(board), do: board |> stage_flows() |> Map.keys() |> MapSet.new()

  @doc """
  Where a flow working in stage `stage_id` picks cards up and drops them off (RE429), worked
  out from board order: `stages` is the board's stages already in `Schemas.Stage.order_stages/1`
  order, substages included. `pulls_from` is the stage immediately before it, `lands_on` the
  stage immediately after it — its own first substage (Review before Done) when it has one,
  otherwise the next main stage. `nil` at either end of the board; both `nil` for a stage id
  not in the list. Returns the elements passed in (structs or maps), not ids. Pure.

  The ONE source of the pulls-from / lands-on rule (AGENTS.md).
  """
  @spec neighbours(integer(), [Stage.t() | map()]) :: %{
          pulls_from: Stage.t() | map() | nil,
          lands_on: Stage.t() | map() | nil
        }
  def neighbours(stage_id, stages) when is_list(stages) do
    case Enum.find_index(stages, &(&1.id == stage_id)) do
      nil -> %{pulls_from: nil, lands_on: nil}
      0 -> %{pulls_from: nil, lands_on: Enum.at(stages, 1)}
      index -> %{pulls_from: Enum.at(stages, index - 1), lands_on: Enum.at(stages, index + 1)}
    end
  end

  @doc """
  Where `flow` picks cards up and drops them off, read from its board's stages FRESH — the DB
  convenience over `neighbours/2`. The engine asks this at the moment it needs the answer
  (`Relay.Runs.RunServer` at landing, `Relay.Runs.Preflight`), never a cached copy.
  """
  @spec neighbours(Flow.t()) :: %{pulls_from: Stage.t() | nil, lands_on: Stage.t() | nil}
  def neighbours(%Flow{board_id: board_id, stage_id: stage_id}), do: neighbours(stage_id, board_stages(board_id))

  @doc """
  The stages a flow may be put on (RE429): the board's main stages of a work type
  (`Schemas.Stage.work_types/0`) that hold no flow, plus `flow`'s own stage, in board order.
  The single source of the Stage-select options in the stage row's Copy picker and the flow editor —
  the same rule `create_flow/2` / `update_flow/2` validate.
  """
  @spec assignable_stages(Board.t() | integer(), Flow.t() | nil) :: [Stage.t()]
  def assignable_stages(%Board{id: board_id}, flow), do: assignable_stages(board_id, flow)

  def assignable_stages(board_id, flow) when is_integer(board_id) do
    own_stage_id = flow && flow.stage_id
    occupied = MapSet.new(Repo.all(from f in Flow, where: f.board_id == ^board_id, select: f.stage_id))

    board_id
    |> board_stages()
    |> Enum.filter(fn stage ->
      is_nil(stage.parent_id) and stage.type in Stage.work_types() and
        (stage.id == own_stage_id or not MapSet.member?(occupied, stage.id))
    end)
  end

  @doc """
  Whether any flow (enabled or disabled) is on this one stage — the single-stage form of
  `stage_flows/1`'s fact. No type guard; callers keep their own.
  """
  @spec ai_stage?(Stage.t() | integer()) :: boolean()
  def ai_stage?(%Stage{id: stage_id}), do: ai_stage?(stage_id)

  def ai_stage?(stage_id) when is_integer(stage_id) do
    Repo.exists?(from f in Flow, where: f.stage_id == ^stage_id)
  end

  @doc """
  The board's flow with `key`, `:stage` preloaded and its derived `pulls_from_stage` /
  `lands_on_stage` and `problem` filled — the shape `Relay.Flows.Document.encode/1` requires.
  The problem is worked out against ALL the board's flows, so an upstream flow can be named.
  nil when the board has no such flow.
  """
  def get_flow_with_stages(%Board{id: board_id}, key) when is_binary(key) do
    from(f in Flow, where: f.board_id == ^board_id and f.key == ^key, preload: :stage)
    |> Repo.one()
    |> with_neighbours(board_id)
  end

  @doc """
  Whether `flow` is **paused** by a broken board shape (RE432) — the ONE definition: it is
  enabled AND carries a shape `problem`. Only reads that fill the virtual `problem`
  (`list_flows/1`, `get_flow_with_stages/2`) can say yes; a flow read any other way (e.g.
  `get_flow!/2`) is never paused.
  """
  @spec paused?(Flow.t()) :: boolean()
  def paused?(%Flow{enabled: enabled, problem: problem}), do: enabled and not is_nil(problem)

  @doc """
  Every broken flow's shape problem on the board (RE430) — the DB convenience over
  `Relay.Flows.Shape.problems/2`: the board's ordered stages plus every flow, enabled or not.
  """
  @spec shape_problems(Board.t() | integer()) :: [Shape.problem()]
  def shape_problems(%Board{id: board_id}), do: shape_problems(board_id)

  def shape_problems(board_id) when is_integer(board_id),
    do: Shape.problems(board_stages(board_id), shape_flows(board_id))

  # The lean `%{key, stage_id, enabled}` read `Shape.problems/2` takes, in `key` order.
  defp shape_flows(board_id) do
    Repo.all(
      from f in Flow,
        where: f.board_id == ^board_id,
        order_by: f.key,
        select: %{key: f.key, stage_id: f.stage_id, enabled: f.enabled}
    )
  end

  # The board's stages in `Schemas.Stage.order_stages/1` order — `Relay.Flows` may not call
  # `Relay.Boards` (which depends on it), so it reads the rows and asks the schema for the order.
  defp board_stages(board_id) do
    Stage.order_stages(Repo.all(from s in Stage, where: s.board_id == ^board_id))
  end

  # Fill the virtual neighbours (RE429) and shape problem (RE430) from the board's CURRENT order —
  # computed on every read, one stage read for the whole list. A problem is worked out against
  # every flow on the board so it can name the upstream flow: for `list_flows/1` that is the list
  # itself; a single flow reads the rest with one lean query.
  defp with_neighbours(nil, _board_id), do: nil

  defp with_neighbours(%Flow{} = flow, board_id), do: hd(with_neighbours([flow], board_id, shape_flows(board_id)))

  defp with_neighbours(flows, board_id) when is_list(flows), do: with_neighbours(flows, board_id, flows)

  defp with_neighbours([], _board_id, _all_flows), do: []

  defp with_neighbours(flows, board_id, all_flows) do
    stages = board_stages(board_id)
    problems = Map.new(Shape.problems(stages, all_flows), &{&1.flow_key, &1})

    Enum.map(flows, fn flow ->
      %{pulls_from: pulls_from, lands_on: lands_on} = neighbours(flow.stage_id, stages)
      %{flow | pulls_from_stage: pulls_from, lands_on_stage: lands_on, problem: Map.get(problems, flow.key)}
    end)
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
      |> validate_stage()

    case Repo.insert(changeset) do
      {:ok, flow} -> snapshot!(flow)
      {:error, cs} -> Repo.rollback(cs)
    end
  end

  @doc """
  Updates a flow's definition with the same validation as `create_flow/2` — including moving
  it to another stage, which must be free (a flow staying on its own stage is no collision).
  """
  def update_flow(%Flow{} = flow, attrs) do
    flow
    |> Flow.changeset(attrs)
    |> validate_stage()
    |> Repo.update()
  end

  @doc """
  Enables a flow. A flow always has its stage and a stage holds one flow (RE429), so there is
  nothing left to check. Returns `{:ok, flow} | {:error, changeset}`.
  """
  def enable_flow(%Flow{} = flow) do
    flow
    |> Changeset.change(enabled: true)
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
  survive re-seeding. The authored trigger stage *name* is resolved against the
  board's stages at seed time; a default is created only when that names a stage
  on the board that can take it (a free main work stage, the rule `create_flow/2`
  validates) — otherwise it is skipped. A stageless flow never exists (RE429).
  """
  def seed_default_flows!(%Board{id: board_id} = board) do
    existing = MapSet.new(Repo.all(from f in Flow, where: f.board_id == ^board_id, select: f.key))
    stage_ids = Map.new(Repo.all(from s in Stage, where: s.board_id == ^board_id, select: {s.name, s.id}))

    for %{trigger: %{stage: name}} = default <- DefaultLibrary.all(),
        not MapSet.member?(existing, default.key),
        stage_id = stage_ids[name],
        not is_nil(stage_id) do
      changeset =
        %Flow{board_id: board.id}
        |> Flow.changeset(default |> Map.delete(:trigger) |> Map.put(:stage_id, stage_id))
        |> validate_stage()

      if changeset.valid?, do: changeset |> Repo.insert!() |> snapshot!()
    end

    :ok
  end

  @doc """
  Whether the flow's definition (nodes, edges, isolation) differs from the
  default library's definition for its key — normalized comparison, so the
  library's dense attr maps and the embedded structs compare field-by-field.
  A flow whose key isn't a library key at all (e.g. a copy) is always
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
  Copies `flow`'s definition (nodes, edges, isolation) onto `stage` as a new, **disabled** flow
  at v1 (RE429 — replaces Duplicate: a stage holds one flow, so a copy needs a stage of its
  own). `stage` must pass the same rule as `create_flow/2` — on the flow's board, a main work
  stage, holding no flow — or the result is `{:error, changeset}` with the error on `:stage_id`.
  The key is `"<key>-<stage-slug>"` (`code` onto `QA` → `code-qa`), suffixed `-2`, `-3`, …
  until unique. Inserts the v1 snapshot in the same transaction.
  """
  @spec copy_flow(Flow.t(), Stage.t()) :: {:ok, Flow.t()} | {:error, Changeset.t()}
  def copy_flow(%Flow{} = flow, %Stage{} = stage) do
    attrs = %{
      key: copy_key(flow, stage),
      isolation: flow.isolation,
      stage_id: stage.id,
      nodes: Enum.map(flow.nodes, &Map.take(&1, Flow.Node.fields())),
      edges: Enum.map(flow.edges, &Map.take(&1, Flow.Edge.fields()))
    }

    Repo.transaction(fn -> insert_flow!(%Board{id: flow.board_id}, attrs) end)
  end

  @doc """
  The key `copy_flow/2` gives a copy of `flow` on `stage` — `"<key>-<stage-slug>"`, suffixed
  until unique. Backs the stage row's Copy-to-another-stage key preview (RE431), so the preview
  and the copy can never disagree.
  """
  @spec copy_key(Flow.t(), Stage.t()) :: String.t()
  def copy_key(%Flow{} = flow, %Stage{} = stage) do
    unique_key(flow.board_id, "#{flow.key}-#{stage_slug(stage.name)}")
  end

  @doc """
  The default-library keys, in library order, that have no flow with that key on `board` —
  what the stage row's **+ Add flow** panel offers to re-add (RE431).
  """
  @spec addable_defaults(Board.t() | integer()) :: [String.t()]
  def addable_defaults(%Board{id: board_id}), do: addable_defaults(board_id)

  def addable_defaults(board_id) when is_integer(board_id) do
    taken = MapSet.new(Repo.all(from f in Flow, where: f.board_id == ^board_id, select: f.key))

    for %{key: key} <- DefaultLibrary.all(), not MapSet.member?(taken, key), do: key
  end

  @doc """
  Puts a new, **disabled** flow at v1 (with its v1 snapshot) on `stage` — the stage row's
  **+ Add flow** (RE431). `{:default, key}` takes that library flow's definition under
  `unique_key(board, key)`; `:blank` makes a bare `start → done` graph keyed by the stage-name
  slug (`"flow"` when the name has none). Validated like `create_flow/2`: an occupied, non-work
  or substage `stage` returns `{:error, changeset}` with the error on `:stage_id`. A key not in
  the library returns `{:error, :not_a_default}`.
  """
  @spec add_flow(Stage.t(), {:default, String.t()} | :blank) ::
          {:ok, Flow.t()} | {:error, :not_a_default} | {:error, Changeset.t()}
  def add_flow(%Stage{} = stage, {:default, key}) when is_binary(key) do
    case default_for(key) do
      nil ->
        {:error, :not_a_default}

      default ->
        attrs =
          default
          |> Map.delete(:trigger)
          |> Map.merge(%{stage_id: stage.id, key: unique_key(stage.board_id, key)})

        insert_on_stage(stage, attrs)
    end
  end

  def add_flow(%Stage{} = stage, :blank) do
    base = with "" <- stage_slug(stage.name), do: "flow"

    insert_on_stage(stage, %{
      key: unique_key(stage.board_id, base),
      isolation: :shared_clean,
      stage_id: stage.id,
      nodes: [],
      edges: [%{from: "start", to: "done"}]
    })
  end

  defp insert_on_stage(%Stage{board_id: board_id}, attrs) do
    Repo.transaction(fn -> insert_flow!(%Board{id: board_id}, attrs) end)
  end

  defp stage_slug(name) do
    name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
  end

  @doc """
  The editor's save path. Validates the working copy like `update_flow/2`. When the
  **definition** (nodes, edges, isolation) changed, bumps `version` to n+1 and writes a new
  immutable snapshot; a stage-only change saves with no bump (the stage is per-board wiring,
  not part of the versioned definition). Runs entirely in one transaction. The returned flow
  has `:stage` preloaded and its derived neighbours filled.
  """
  def save_definition(%Flow{} = flow, attrs) do
    fn -> save_and_maybe_bump(flow, attrs) end
    |> Repo.transaction()
    |> preload_saved()
  end

  @doc """
  Creates or updates `key`'s flow on `board` from a canonical `Relay.Flows.Document` (RLY-241) —
  the `PUT /api/flows/:key` write path, and the reconcile engine's.

  One transaction, in order: decode → key check → resolve the trigger's stage NAME against this
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

  A trigger absent from the document leaves the flow's stage alone; a new flow with no stage is
  `{:error, {:invalid, changeset}}` (`"can't be blank"` on `:stage_id`).

  Returns `{:ok, :created | :updated, flow}` with its stage preloaded, or one of
  `{:error, {:invalid_document, reason}}`, `{:error, :key_mismatch}`,
  `{:error, {:unknown_stages, names}}`, `{:error, {:stage_occupied, %{stage: name, flow: key}}}`
  (the trigger names a stage another flow already holds — render with `stage_occupied_message/1`),
  `{:error, :stale_version}`, `{:error, {:invalid, changeset}}`.
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

    stage = resolve_trigger!(board, Map.get(attrs, :trigger))
    check_stage_free!(stage, key, Map.get(attrs, :trigger))

    definition =
      attrs
      |> Map.take([:isolation, :nodes, :edges])
      |> Map.put(:key, key)
      |> Map.merge(stage)

    {tag, flow} = write_document!(board, existing, definition)
    reconcile_enabled!(flow, Map.get(attrs, :enabled))

    {tag, get_flow_with_stages(board, key)}
  end

  defp check_document_version!(nil, _version), do: :ok
  defp check_document_version!(_flow, nil), do: :ok
  defp check_document_version!(%Flow{version: version}, version), do: :ok
  defp check_document_version!(_flow, _stale), do: Repo.rollback(:stale_version)

  # A name, not an id — that is what makes a document portable across boards. A null stage
  # resolves to nil and fails the changeset (a flow always has a stage); a trigger absent from
  # the document leaves the flow's current stage alone.
  defp resolve_trigger!(_board, nil), do: %{}
  defp resolve_trigger!(_board, %{stage: nil}), do: %{stage_id: nil}

  defp resolve_trigger!(%Board{id: board_id}, %{stage: name}) do
    case Repo.one(from s in Stage, where: s.board_id == ^board_id and s.name == ^name, select: s.id) do
      nil -> Repo.rollback({:unknown_stages, [name]})
      stage_id -> %{stage_id: stage_id}
    end
  end

  # A stage holds one flow (RE429): a push naming a stage another key already sits on is refused
  # before any write, naming the occupant — the push never silently moves or replaces a flow.
  defp check_stage_free!(%{stage_id: stage_id}, key, %{stage: name}) when is_integer(stage_id) do
    case stage_flow(stage_id) do
      %Flow{key: other} when other != key -> Repo.rollback({:stage_occupied, %{stage: name, flow: other}})
      _free_or_own -> :ok
    end
  end

  defp check_stage_free!(_stage, _key, _trigger), do: :ok

  @doc """
  The sentence for `{:error, {:stage_occupied, details}}` from `upsert_from_document/3` — the one
  copy, so every surface words the refusal the same way.
  """
  @spec stage_occupied_message(%{stage: String.t(), flow: String.t()}) :: String.t()
  def stage_occupied_message(%{stage: stage, flow: flow}),
    do: "stage `#{stage}` already has flow `#{flow}` — delete it or push to that key"

  defp write_document!(board, nil, definition), do: {:created, insert_flow!(board, definition)}

  defp write_document!(_board, %Flow{} = flow, definition), do: {:updated, save_and_maybe_bump(flow, definition)}

  # Route through enable_flow/1 / disable_flow/1 so any rule they carry applies here too.
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
  definition for its key. The stage and `enabled` are untouched. Routes through
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
  Backs both `copy_flow/2`'s key (`copy_key/2`) and `add_flow/2`'s.
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
  creates flows at v1 and the only path that bumps a flow past 1 is a human editing it from
  Settings › Stages (the stage's FLOW band → the flow editor, `save_definition/2`). So `version > 1` means hand-edited — its edits are
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
    {:ok, flow |> Repo.preload(:stage, force: true) |> with_neighbours(flow.board_id)}
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
  # would make the next library sync skip this flow (version > 1). Stage/enabled are untouched;
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

  # The one-stage rule (RE429), checked in order: the stage is on the flow's board, a main
  # stage, of a work type, and holds no other flow (the occupant named). A missing stage is left
  # to `validate_required/2`; `flows_stage_id_index` backstops a race on occupancy.
  defp validate_stage(changeset) do
    case Changeset.get_field(changeset, :stage_id) do
      nil -> changeset
      stage_id -> stage_error(changeset, Repo.get(Stage, stage_id))
    end
  end

  defp stage_error(changeset, stage) do
    board_id = Changeset.get_field(changeset, :board_id)

    message =
      cond do
        is_nil(stage) or stage.board_id != board_id -> "stage is not on this board"
        not is_nil(stage.parent_id) -> "flows attach to main stages only, not substages"
        stage.type not in Stage.work_types() -> "a flow can only work in a work or planning stage"
        occupant = occupant_key(stage.id, changeset.data.id) -> "stage already has flow `#{occupant}`"
        true -> nil
      end

    if message, do: Changeset.add_error(changeset, :stage_id, message), else: changeset
  end

  defp occupant_key(stage_id, own_id) do
    query = from f in Flow, where: f.stage_id == ^stage_id, select: f.key
    query = if own_id, do: where(query, [f], f.id != ^own_id), else: query
    Repo.one(query)
  end
end
