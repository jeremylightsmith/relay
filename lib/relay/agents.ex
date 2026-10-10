defmodule Relay.Agents do
  @moduledoc """
  The Agents context (RE433): a board's **harnesses** (`Schemas.Harness` — an agent CLI's command
  template plus its closed model list) and its named **agents** (`Schemas.Agent` — a harness plus
  one of its models), exactly one of which is the board default (`boards.default_agent_id`).

  Flow nodes name an agent by `name` in their `llm` field (nil = the board default). This context
  owns being **red** — an agent whose model has left its harness's list — in `red?/1`, the one
  definition every consumer calls.

  `Relay.Flows` depends on this context (it validates a node's `llm` against `agent_names/1`), so
  this one never calls `Relay.Flows`: a rename, a delete refusal and `node_usage/1` read and write
  `Schemas.Flow` rows directly through `Relay.Repo`.

  Every board is seeded by `ensure_seeded!/1` — from `Relay.Boards.create_board/2`, from
  `Relay.Flows.seed_default_flows!/1`, and as the backstop for boards inserted any other way.
  """

  use Boundary, deps: [Relay.Repo, Schemas]

  import Ecto.Query

  alias Ecto.Changeset
  alias Relay.Repo
  alias Schemas.Agent
  alias Schemas.Board
  alias Schemas.Flow
  alias Schemas.Harness

  @default_harness_key "claude-code"

  @seed_harnesses [
    %{
      key: @default_harness_key,
      name: "Claude Code",
      command:
        "claude -p {prompt} --model {model} --permission-mode auto --verbose --output-format stream-json [--effort {effort}] [--agent {subagent}]",
      models: ["opus", "sonnet", "haiku"],
      resume_command:
        "claude -p --resume {session} {prompt} --model {model} --permission-mode auto --verbose --output-format stream-json [--effort {effort}] [--agent {subagent}]",
      session_id_path: ".session_id",
      signed_in_check: "claude auth status"
    },
    %{
      key: "codex",
      name: "Codex",
      command: "codex exec --json --model {model} --cd {worktree} [-c model_reasoning_effort={effort}] {prompt}",
      # The `visibility: "list"` entries of codex-cli 0.160.0's ~/.codex/models_cache.json (2026-10-09).
      models: ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"],
      resume_command: "codex exec resume --json --model {model} {session} {prompt}",
      session_id_path: ".thread_id",
      signed_in_check: "codex login status"
    },
    %{
      key: "gemini-cli",
      name: "Gemini CLI",
      command: "gemini -p {prompt} --model {model}",
      models: ["gemini-2.5-pro", "gemini-2.5-flash"],
      resume_command: nil,
      session_id_path: nil,
      signed_in_check: nil
    }
  ]

  @doc "The key of the harness every pre-agents node ran on — the legacy harness."
  @spec default_harness_key() :: String.t()
  def default_harness_key, do: @default_harness_key

  @doc "The harnesses every board is seeded with, in order — the ONE copy (the migration freezes its own)."
  @spec seed_harnesses() :: [map()]
  def seed_harnesses, do: @seed_harnesses

  @doc """
  Idempotently seeds `board`: inserts each seed harness whose `key` the board lacks. A board with
  **no agents** also gets one `claude-code` agent per `Schemas.Flow.Node.legacy_models/0` entry,
  and "Claude Opus" becomes its default. A board that already has agents keeps them and its
  default untouched. Serialized on the board row, so concurrent callers can't double-seed.
  """
  @spec ensure_seeded!(Board.t() | integer()) :: :ok
  def ensure_seeded!(board) do
    board_id = board_id(board)

    Repo.transaction(fn ->
      Repo.one!(from b in Board, where: b.id == ^board_id, select: b.id, lock: "FOR UPDATE")
      existing = MapSet.new(Repo.all(from h in Harness, where: h.board_id == ^board_id, select: h.key))

      for seed <- @seed_harnesses, not MapSet.member?(existing, seed.key) do
        Repo.insert!(struct(Harness, Map.put(seed, :board_id, board_id)))
      end

      if not Repo.exists?(from a in Agent, where: a.board_id == ^board_id), do: seed_agents!(board_id)
    end)

    :ok
  end

  # Ordered by the claude-code seed's model list, so "Claude Opus" (the default) comes first.
  defp seed_agents!(board_id) do
    harness = Repo.get_by!(Harness, board_id: board_id, key: @default_harness_key)
    names = Schemas.Flow.Node.legacy_models()
    [%{models: models}] = Enum.filter(@seed_harnesses, &(&1.key == @default_harness_key))

    [default | _] =
      for model <- models, name = names[model], not is_nil(name) do
        Repo.insert!(%Agent{board_id: board_id, harness_id: harness.id, name: name, model: model})
      end

    Repo.update_all(from(b in Board, where: b.id == ^board_id), set: [default_agent_id: default.id])
  end

  # ---------------------------------------------------------------- reads

  @doc "The board's harnesses, oldest first."
  @spec list_harnesses(Board.t() | integer()) :: [Harness.t()]
  def list_harnesses(board) do
    Repo.all(from h in Harness, where: h.board_id == ^board_id(board), order_by: [h.inserted_at, h.id])
  end

  @doc "One of the board's harnesses; raises for another board's id."
  @spec get_harness!(Board.t() | integer(), integer()) :: Harness.t()
  def get_harness!(board, id), do: Repo.get_by!(Harness, id: id, board_id: board_id(board))

  @doc "The board's agents in creation order, `:harness` preloaded."
  @spec list_agents(Board.t() | integer()) :: [Agent.t()]
  def list_agents(board) do
    Repo.all(from a in Agent, where: a.board_id == ^board_id(board), order_by: a.id, preload: :harness)
  end

  @doc "One of the board's agents, `:harness` preloaded; raises for another board's id."
  @spec get_agent!(Board.t() | integer(), integer()) :: Agent.t()
  def get_agent!(board, id) do
    Agent |> Repo.get_by!(id: id, board_id: board_id(board)) |> Repo.preload(:harness)
  end

  @doc "The board's default agent (read fresh, so a stale board struct still answers), or nil."
  @spec default_agent(Board.t() | integer()) :: Agent.t() | nil
  def default_agent(board) do
    Repo.one(
      from a in Agent,
        join: b in Board,
        on: b.default_agent_id == a.id,
        where: b.id == ^board_id(board),
        preload: :harness
    )
  end

  @doc """
  True when the agent's model is no longer in its harness's list — a harness edit dropped it. The
  ONE definition of a red agent; needs `:harness` loaded.
  """
  @spec red?(Agent.t()) :: boolean()
  def red?(%Agent{model: model, harness: %Harness{models: models}}), do: model not in models

  @doc "The names of the board's agents."
  @spec agent_names(Board.t() | integer()) :: MapSet.t(String.t())
  def agent_names(board) do
    MapSet.new(Repo.all(from a in Agent, where: a.board_id == ^board_id(board), select: a.name))
  end

  @doc """
  Agent name → the `{flow_key, node_key}` pairs naming it explicitly in `llm` (flows by key, nodes
  in flow order). Nodes inheriting the default are not counted.
  """
  @spec node_usage(Board.t() | integer()) :: %{String.t() => [{String.t(), String.t()}]}
  def node_usage(board) do
    pairs =
      for flow <- board_flows(board_id(board)), %{llm: llm} = node <- flow.nodes, is_binary(llm) do
        {llm, {flow.key, node.key}}
      end

    Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))
  end

  defp board_flows(board_id), do: Repo.all(from f in Flow, where: f.board_id == ^board_id, order_by: f.key)

  # ---------------------------------------------------------------- run time

  @doc """
  Resolves a node's `llm` on `board` to the agent it runs on (RE433), `:harness` preloaded. nil
  means the board default — a board with none is seeded first (`ensure_seeded!/1`). A red agent
  (`red?/1`) comes back `{:red, agent}` so the caller can refuse it loudly.
  """
  @spec resolve(Board.t() | integer(), String.t() | nil) ::
          {:ok, Agent.t()} | {:red, Agent.t()} | {:error, {:unknown_agent, String.t()}}
  def resolve(board, nil) do
    agent =
      default_agent(board) ||
        (
          :ok = ensure_seeded!(board)
          default_agent(board)
        )

    verdict(agent)
  end

  def resolve(board, name) when is_binary(name) do
    case Repo.one(from a in Agent, where: a.board_id == ^board_id(board) and a.name == ^name, preload: :harness) do
      nil -> {:error, {:unknown_agent, name}}
      agent -> verdict(agent)
    end
  end

  defp verdict(agent), do: if(red?(agent), do: {:red, agent}, else: {:ok, agent})

  @doc "Why a red agent's node refused to run — the blocked detail the card shows."
  @spec red_agent_detail(Agent.t()) :: String.t()
  def red_agent_detail(%Agent{name: name, model: model, harness: %Harness{name: harness}}) do
    ~s(agent "#{name}" uses model "#{model}", which #{harness} no longer offers — pick a model in Settings → Agents)
  end

  @doc "Why a node naming an agent the board lacks refused to run."
  @spec unknown_agent_detail(String.t(), String.t()) :: String.t()
  def unknown_agent_detail(name, node_key) do
    ~s(node "#{node_key}" names LLM "#{name}", which is not an agent on this board — pick one in the flow editor)
  end

  @doc "A harness as the runner reads it off `GET /api/harnesses` — string keys."
  @spec harness_wire(Harness.t()) :: map()
  def harness_wire(%Harness{} = h) do
    %{
      "key" => h.key,
      "name" => h.name,
      "command" => h.command,
      "models" => h.models,
      "resume_command" => h.resume_command,
      "session_id_path" => h.session_id_path,
      "signed_in_check" => h.signed_in_check
    }
  end

  @doc """
  The lowercase hex SHA-256 of the board's harness definitions in wire shape (`list_harnesses/1`
  order, keys sorted). Free of ids and timestamps, so identical definitions digest identically —
  the heartbeat replies it and the runner refetches `GET /api/harnesses` when it moves.
  """
  @spec harnesses_digest(Board.t() | integer()) :: String.t()
  def harnesses_digest(board) do
    wire = for h <- list_harnesses(board), do: h |> harness_wire() |> Enum.sort() |> Jason.OrderedObject.new()
    :sha256 |> :crypto.hash(Jason.encode!(wire)) |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------- harnesses

  @doc "A changeset for a harness form."
  @spec change_harness(Harness.t(), map()) :: Changeset.t()
  def change_harness(%Harness{} = harness, attrs \\ %{}), do: Harness.changeset(harness, attrs)

  @doc """
  Creates a harness on `board`. Its `key` is the name's slug (lowercase, runs of non-`[a-z0-9]` →
  `-`, trimmed); the first free key wins — `pi`, then `pi-2`, `pi-3`.
  """
  @spec create_harness(Board.t(), map()) :: {:ok, Harness.t()} | {:error, Changeset.t()}
  def create_harness(%Board{id: board_id}, attrs) do
    %Harness{board_id: board_id}
    |> Harness.changeset(attrs)
    |> then(&Changeset.put_change(&1, :key, free_key(board_id, Changeset.get_field(&1, :name))))
    |> Repo.insert()
  end

  defp free_key(board_id, name) do
    base =
      case name |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-") do
        "" -> "harness"
        slug -> slug
      end

    taken = MapSet.new(Repo.all(from h in Harness, where: h.board_id == ^board_id, select: h.key))

    [base]
    |> Stream.concat(Stream.map(Stream.iterate(2, &(&1 + 1)), &"#{base}-#{&1}"))
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  @doc """
  Updates a harness. Never changes `key`. Dropping a model an agent uses succeeds — that agent
  turns red (`red?/1`) rather than the edit being refused.
  """
  @spec update_harness(Harness.t(), map()) :: {:ok, Harness.t()} | {:error, Changeset.t()}
  def update_harness(%Harness{} = harness, attrs) do
    harness
    |> Harness.changeset(attrs)
    |> Repo.update()
  end

  @doc "Deletes a harness no agent uses; otherwise refuses, naming the agents (sorted)."
  @spec delete_harness(Harness.t()) :: {:ok, Harness.t()} | {:error, {:in_use, [String.t()]}}
  def delete_harness(%Harness{id: id} = harness) do
    case Repo.all(from a in Agent, where: a.harness_id == ^id, select: a.name, order_by: a.name) do
      [] -> Repo.delete(harness)
      names -> {:error, {:in_use, names}}
    end
  end

  # ---------------------------------------------------------------- agents

  @doc "A changeset for an agent form, validated against the harness the attrs (or the agent) name."
  @spec change_agent(Agent.t(), map()) :: Changeset.t()
  def change_agent(%Agent{} = agent, attrs \\ %{}) do
    harness_id = attr_harness_id(attrs) || agent.harness_id
    harness = (harness_id && Repo.get_by(Harness, id: harness_id, board_id: agent.board_id)) || %Harness{}
    Agent.changeset(agent, attrs, harness)
  end

  @doc """
  Creates an agent on `board` from string-keyed `"name"`, `"harness_id"` and `"model"`. The
  harness must be on the board and the model in its list. Returns the agent with `:harness`
  preloaded.
  """
  @spec create_agent(Board.t(), map()) :: {:ok, Agent.t()} | {:error, Changeset.t()}
  def create_agent(%Board{id: board_id}, attrs) do
    agent = %Agent{board_id: board_id}

    case attr_harness_id(attrs) && Repo.get_by(Harness, id: attr_harness_id(attrs), board_id: board_id) do
      %Harness{} = harness ->
        agent
        |> Agent.changeset(attrs, harness)
        |> Repo.insert()
        |> preload_harness()

      _missing ->
        agent
        |> Changeset.cast(attrs, [:name, :harness_id, :model])
        |> Changeset.add_error(:harness_id, "is not a harness on this board")
        |> Changeset.apply_action(:insert)
    end
  end

  defp attr_harness_id(attrs) do
    case Ecto.Type.cast(:id, Map.get(attrs, "harness_id", Map.get(attrs, :harness_id))) do
      {:ok, id} when is_integer(id) -> id
      _ -> nil
    end
  end

  @doc """
  Updates an agent's `name` and `model` (never its harness). A rename relabels `llm` on every node
  of the board's flows in the same transaction, **without** bumping the flows' version or
  snapshotting: it is the same agent under a new name. Old `flow_versions` keep the old name.
  """
  @spec update_agent(Agent.t(), map()) :: {:ok, Agent.t()} | {:error, Changeset.t()}
  def update_agent(%Agent{} = agent, attrs) do
    agent = Repo.preload(agent, :harness)
    changeset = Agent.changeset(agent, Map.drop(attrs, ["harness_id", :harness_id]), agent.harness)

    Repo.transaction(fn ->
      case Repo.update(changeset) do
        {:ok, updated} ->
          if updated.name != agent.name, do: relabel_nodes!(agent.board_id, agent.name, updated.name)
          updated

        {:error, cs} ->
          Repo.rollback(cs)
      end
    end)
  end

  defp relabel_nodes!(board_id, old, new) do
    for flow <- board_flows(board_id), Enum.any?(flow.nodes, &(&1.llm == old)) do
      flow
      |> Changeset.change()
      |> Changeset.put_embed(:nodes, Enum.map(flow.nodes, &relabel(&1, old, new)))
      |> Repo.update!()
    end
  end

  defp relabel(%{llm: old} = node, old, new), do: %{node | llm: new}
  defp relabel(node, _old, _new), do: node

  @doc """
  Deletes an agent. Refuses the board default (`{:error, :default}`) and an agent a flow node
  names explicitly (`{:error, {:in_use, [{flow_key, node_key}]}}`).
  """
  @spec delete_agent(Agent.t()) ::
          {:ok, Agent.t()} | {:error, :default} | {:error, {:in_use, [{String.t(), String.t()}]}}
  def delete_agent(%Agent{} = agent) do
    default_id = Repo.one(from b in Board, where: b.id == ^agent.board_id, select: b.default_agent_id)

    cond do
      default_id == agent.id -> {:error, :default}
      pairs = node_usage(agent.board_id)[agent.name] -> {:error, {:in_use, pairs}}
      true -> Repo.delete(agent)
    end
  end

  @doc "Makes `agent` the board's default."
  @spec set_default_agent(Board.t(), Agent.t()) :: {:ok, Board.t()}
  def set_default_agent(%Board{id: board_id} = board, %Agent{board_id: board_id} = agent) do
    board
    |> Changeset.change(default_agent_id: agent.id)
    |> Repo.update()
  end

  defp preload_harness({:ok, agent}), do: {:ok, Repo.preload(agent, :harness)}
  defp preload_harness(error), do: error

  defp board_id(%Board{id: id}), do: id
  defp board_id(id) when is_integer(id), do: id
end
