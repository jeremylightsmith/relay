defmodule Relay.ValueStreamFixtures do
  @moduledoc """
  RE146 test fixtures: a board mirroring RE's stages (three queues before `Next up`) and
  helpers that write back-dated history exactly as `Relay.Cards` records it (names + ids).
  `Relay.ValueStream` folds activity rows in **id order**, so call these in chronological
  order. Boundary checks are off — test-only support that reaches into any context.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import Relay.Factory

  alias Relay.Boards
  alias Schemas.Flow.Edge

  @t0 ~U[2026-09-01 00:00:00Z]

  def t0, do: @t0

  @doc "`secs` seconds after `base` (default `t0/0`)."
  def at(secs, base \\ @t0), do: DateTime.add(base, secs, :second)

  @doc """
  Backlog, Triage, Next up (queues) | Spec (+ Review, Done substages) | Plan (+ Done) | Code |
  Review (top-level gate) | Done (terminal). `code_ai_enabled: false` makes Code human-only.
  """
  def re_board(opts \\ []) do
    board = insert(:board, key: "RE")

    stages = %{
      backlog: stage(board, "Backlog", :queue, :unstarted, 1, false),
      triage: stage(board, "Triage", :queue, :unstarted, 2, false),
      next_up: stage(board, "Next up", :queue, :unstarted, 3, false),
      spec: stage(board, "Spec", :planning, :planning, 4, true),
      plan: stage(board, "Plan", :planning, :planning, 5, true),
      code: stage(board, "Code", :work, :in_progress, 6, Keyword.get(opts, :code_ai_enabled, true)),
      review: stage(board, "Review", :review, :in_progress, 7, false),
      done: stage(board, "Done", :done, :complete, 8, false)
    }

    {:ok, spec_review} = Boards.enable_lane(stages.spec, :review)
    {:ok, spec_done} = Boards.enable_lane(stages.spec, :done)
    {:ok, plan_done} = Boards.enable_lane(stages.plan, :done)

    Map.merge(stages, %{board: board, spec_review: spec_review, spec_done: spec_done, plan_done: plan_done})
  end

  defp stage(board, name, type, category, position, ai_enabled) do
    insert(:stage,
      board: board,
      name: name,
      type: type,
      category: category,
      position: position,
      ai_enabled: ai_enabled
    )
  end

  @doc "A card that now sits in `stage` (`:ready` by default — Done when `stage` is terminal), created at `created_at`."
  def card_in(stage, created_at, attrs \\ []) do
    insert(
      :card,
      Keyword.merge([stage: stage, status: :ready, inserted_at: created_at, updated_at: created_at], attrs)
    )
  end

  @doc "A `:moved` row from `from` to `to` at `at`, meta exactly as `Relay.Cards` writes it."
  def moved(card, from, to, at) do
    insert(:activity, card: card, type: :moved, meta: transition_meta(from, to), inserted_at: at, updated_at: at)
  end

  @doc "Walks `card` along `path` (`[{stage, secs}]`): one `:moved` row per hop at `at(secs, base)`. The first element's secs is ignored."
  def walk(card, path, base \\ @t0) do
    path
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [{from, _}, {to, secs}] -> moved(card, from, to, at(secs, base)) end)
  end

  @doc "An `:approved` / `:rejected` row with `Relay.Cards`' meta shape."
  def decided(card, type, from, to, at) when type in [:approved, :rejected] do
    insert(:activity, card: card, type: type, meta: transition_meta(from, to), inserted_at: at, updated_at: at)
  end

  def parked(card, at) do
    insert(:activity, card: card, type: :needs_input, meta: %{"question" => "?"}, inserted_at: at, updated_at: at)
  end

  def answered(card, at) do
    insert(:activity, card: card, type: :input_answered, meta: %{}, inserted_at: at, updated_at: at)
  end

  @doc """
  One node execution on a fresh, finished (`:done`) run of `card` (`flow_key` default
  `"code"`) — finished so several can coexist under the one-active-run-per-card index;
  `finished_at` may be nil (the execution is still open).
  """
  def executed(card, node_key, started_at, finished_at, opts \\ []) do
    run = insert(:run, card: card, flow_key: Keyword.get(opts, :flow_key, "code"), status: :done)

    insert(:node_execution,
      run: run,
      node_key: node_key,
      started_at: started_at,
      finished_at: finished_at,
      cost: Keyword.get(opts, :cost)
    )
  end

  @doc "A `code` flow whose node roles are implement → :do, spec_review → :check, fix → :fix."
  def code_flow(board) do
    insert(:flow,
      board: board,
      key: "code",
      nodes: [
        %Schemas.Flow.Node{key: "implement", type: :agent, run: "/implement"},
        %Schemas.Flow.Node{key: "spec_review", type: :gate, run: "true"},
        %Schemas.Flow.Node{key: "fix", type: :agent, run: "/fix"}
      ],
      edges: [
        %Edge{from: "start", to: "implement"},
        %Edge{from: "implement", to: "spec_review", on: :succeeded},
        %Edge{from: "spec_review", to: "fix", on: :failed},
        %Edge{from: "fix", to: "spec_review", on: :succeeded},
        %Edge{from: "spec_review", to: "done", on: :succeeded}
      ]
    )
  end

  defp transition_meta(from, to) do
    %{
      "from_stage" => Boards.stage_display_name(from),
      "to_stage" => Boards.stage_display_name(to),
      "from_stage_id" => from.id,
      "to_stage_id" => to.id
    }
  end
end
