defmodule Relay.Flows.Shape do
  @moduledoc """
  The ONE source of the **shape rule** (RE430) and every word that explains a broken one.

  The rule: the column just before a flow's stage — in board order, substages included
  (`Schemas.Stage.order_stages/1`) — must be somewhere a card can rest, a `:queue` or `:done`
  column, and there must be a column after it to land on. Pickup and drop-off come from
  `Relay.Flows.neighbours/2`; this module never re-derives "the column before / after".

  A flow that breaks the rule has exactly one `t:problem/0`, of the first kind in `kinds/0`
  that applies, carrying a structured `what` / `why` / `fixes` / `columns` explanation. The
  web layer, the API and `./relay` render `what`, `why` and each fix's `label` verbatim — they
  never re-word them. Nothing here is stored: a problem is recomputed from the board on read.

  Pure — no Repo access; `Relay.Flows.shape_problems/1` is the DB convenience.
  """

  alias Relay.Flows
  alias Schemas.Stage

  @kinds [:no_upstream, :upstream_review, :upstream_working, :no_downstream]
  @fix_actions [:enable_lane, :insert_queue_stage, :add_stage_after]

  @type kind :: :no_upstream | :upstream_review | :upstream_working | :no_downstream

  @type fix ::
          %{action: :enable_lane, stage_id: integer(), lane: :done, label: String.t()}
          | %{action: :insert_queue_stage, before_stage_id: integer(), name: String.t(), label: String.t()}
          | %{action: :add_stage_after, stage_id: integer(), label: String.t()}

  @type column :: %{stage_id: integer(), name: String.t(), type: atom(), mark: :self | :offending | nil}

  @type problem :: %{
          flow_key: String.t(),
          stage_id: integer(),
          enabled: boolean(),
          kind: kind(),
          what: String.t(),
          why: String.t(),
          fixes: [fix()],
          columns: [column()]
        }

  @rest_sentence "Each upstream card needs somewhere to rest when it's finished before the next flow can take it."

  @doc "The closed set of problem kinds, in the order they are checked."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The closed set of fix actions a problem may offer, in order."
  @spec fix_actions() :: [:enable_lane | :insert_queue_stage | :add_stage_after]
  def fix_actions, do: @fix_actions

  @doc """
  Every broken flow's problem — the ONE source of the shape rule. `stages` is the board's
  stages in `Schemas.Stage.order_stages/1` order (each with `:id, :name, :type, :parent_id`);
  `flows` each carry `:key, :stage_id, :enabled`. One problem per broken flow, in the order the
  flows were passed; healthy flows, and a flow whose stage is not in `stages`, contribute
  nothing. Disabled flows are checked too (their problem carries `enabled: false`) and named as
  an upstream flow. Pure.
  """
  @spec problems([Stage.t() | map()], [map()]) :: [problem()]
  def problems(stages, flows) when is_list(stages) and is_list(flows) do
    flow_keys_by_stage = Map.new(flows, &{&1.stage_id, &1.key})

    Enum.flat_map(flows, fn flow ->
      case Enum.find_index(stages, &(&1.id == flow.stage_id)) do
        nil -> []
        index -> List.wrap(problem(flow, index, stages, flow_keys_by_stage))
      end
    end)
  end

  defp problem(flow, index, stages, flow_keys_by_stage) do
    stage = Enum.at(stages, index)
    %{pulls_from: pulls_from, lands_on: lands_on} = Flows.neighbours(stage.id, stages)

    case classify(pulls_from, lands_on) do
      nil ->
        nil

      kind ->
        explained = explain(kind, flow, stage, pulls_from, stages, flow_keys_by_stage)
        offender = if kind in [:upstream_review, :upstream_working], do: pulls_from.id

        Map.merge(
          %{flow_key: flow.key, stage_id: stage.id, enabled: flow.enabled, kind: kind},
          Map.put(explained, :columns, columns(stages, index, offender))
        )
    end
  end

  # First applicable kind, in `@kinds` order.
  defp classify(nil, _lands_on), do: :no_upstream
  defp classify(%{type: :review}, _lands_on), do: :upstream_review

  defp classify(%{type: type}, lands_on) do
    cond do
      type in Stage.work_types() -> :upstream_working
      is_nil(lands_on) -> :no_downstream
      true -> nil
    end
  end

  defp explain(:no_upstream, _flow, stage, _pulls_from, _stages, _keys) do
    s = stage.name

    %{
      what: "#{s} is the first column on the board, so there is no column before it.",
      why:
        "A flow only ever pulls work from the column before its stage — Relay never pushes work in. " <>
          "With nothing before #{s}, no card can ever reach the flow.",
      fixes: [insert_queue_fix(stage, "Insert a queue stage before #{s}")]
    }
  end

  defp explain(:upstream_review, _flow, stage, pulls_from, stages, _keys) do
    s = stage.name
    u = display_name(pulls_from, stages)
    main = main_stage(pulls_from, stages)

    %{
      what: "The column before #{s} is **#{u}** — a place where a human approves, not a place where cards rest.",
      why:
        "Approving a card in #{u} moves it straight into #{s}. That is a push: it skips #{s}'s WIP limit " <>
          "and the scheduler, so #{s} can end up with more work than it's allowed.",
      fixes: [
        enable_done_fix(main),
        insert_queue_fix(stage, "Insert a queue stage between #{main.name} and #{s}")
      ]
    }
  end

  defp explain(:upstream_working, flow, stage, pulls_from, _stages, flow_keys_by_stage) do
    s = stage.name
    u = pulls_from.name

    {what, why} =
      case Map.get(flow_keys_by_stage, pulls_from.id) do
        nil ->
          {"Flow **#{flow.key}** pulls from #{u}, a stage where people are still working.",
           "#{s} would pull cards out of #{u} while they are still being worked. " <> @rest_sentence}

        upstream_key ->
          {"Flow **#{flow.key}** pulls from #{u}, which is flow **#{upstream_key}**'s working stage.",
           "#{s} would pull cards out of #{u} while the #{upstream_key} flow is still working them. " <>
             @rest_sentence}
      end

    %{
      what: what,
      why: why,
      fixes: [enable_done_fix(pulls_from), insert_queue_fix(stage, "Insert a queue stage between #{u} and #{s}")]
    }
  end

  defp explain(:no_downstream, _flow, stage, _pulls_from, _stages, _keys) do
    s = stage.name

    %{
      what: "#{s} is the last column on the board, so there is no column after it.",
      why:
        "When a run finishes it moves the card to the next column. " <>
          "With nothing after #{s}, finished cards would have nowhere to go.",
      fixes: [
        enable_done_fix(stage),
        %{action: :add_stage_after, stage_id: stage.id, label: "Add a stage after #{s}"}
      ]
    }
  end

  defp enable_done_fix(main) do
    %{action: :enable_lane, stage_id: main.id, lane: :done, label: "Turn on #{main.name} · #{Stage.lane_word(:done)}"}
  end

  defp insert_queue_fix(stage, label) do
    %{action: :insert_queue_stage, before_stage_id: stage.id, name: "Ready for #{stage.name}", label: label}
  end

  # The board columns from two before to two after the flow's stage, clipped to the board.
  defp columns(stages, index, offender_id) do
    self_id = Enum.at(stages, index).id

    stages
    |> Enum.slice(max(index - 2, 0)..(index + 2)//1)
    |> Enum.map(fn stage ->
      mark =
        cond do
          stage.id == self_id -> :self
          stage.id == offender_id -> :offending
          true -> nil
        end

      %{stage_id: stage.id, name: display_name(stage, stages), type: stage.type, mark: mark}
    end)
  end

  # A main stage is itself; a substage is its parent (Relay.Flows may not call Relay.Boards).
  defp main_stage(%{parent_id: nil} = stage, _stages), do: stage
  defp main_stage(%{parent_id: parent_id} = stage, stages), do: Enum.find(stages, stage, &(&1.id == parent_id))

  defp display_name(%{parent_id: nil, name: name}, _stages), do: name

  defp display_name(%{type: type} = stage, stages) do
    case main_stage(stage, stages) do
      ^stage -> stage.name
      main -> "#{main.name} · #{Stage.lane_word(type)}"
    end
  end

  @doc """
  The ONE JSON projection of a problem, string-keyed with atoms as strings: `flow_key`, `kind`,
  `what`, `why`, `fixes` (`action` + `label`) and `columns` (`stage_id`, `name`, `type`,
  `mark`). The stage id, `enabled` and fix parameters stay off the wire. `nil` → `nil`.
  """
  @spec wire(problem() | nil) :: map() | nil
  def wire(nil), do: nil

  def wire(%{} = problem) do
    %{
      "flow_key" => problem.flow_key,
      "kind" => Atom.to_string(problem.kind),
      "what" => problem.what,
      "why" => problem.why,
      "fixes" => Enum.map(problem.fixes, &%{"action" => Atom.to_string(&1.action), "label" => &1.label}),
      "columns" =>
        Enum.map(problem.columns, fn column ->
          %{
            "stage_id" => column.stage_id,
            "name" => column.name,
            "type" => Atom.to_string(column.type),
            "mark" => column.mark && Atom.to_string(column.mark)
          }
        end)
    }
  end

  @doc "The one sentence that says a flow is paused by its problem."
  @spec paused_detail(problem()) :: String.t()
  def paused_detail(%{flow_key: key}) do
    "Flow **#{key}** is paused: no new runs start until the board is fixed. Runs already going will finish and land."
  end
end
