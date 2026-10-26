defmodule Hamaca.FanOutFixtures do
  @moduledoc """
  RE437 test fixtures: `panel`, the one valid `fan_out` / `fan_in` flow every region test edits.

      start → prep → fo ⇉ a ─────────────┐
                        ⇉ b1 ⇄ b2 ───────┼→ fi → after → done
                        ⇉ c ─────────────┘     ↘ prep (on failed)

  `fo` fans out to three branches (`a`, `b1`→`b2`, `c`), which join at `fi`. The fan-out edges
  carry no `on`. Plain data with atom keys, so a test can edit the lists before handing them to
  `Hamaca.Flows.create_flow/2` or `Schemas.Flow.changeset/2`.

  `three` (`three_nodes/0`, `three_edges/0`) is the engine tests' runnable variant: `b1` loops to
  `b2` on failure, `fi` goes to `done` on success and to `report` on failure.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  @doc "The panel's nodes, in node order."
  def panel_nodes do
    [
      %{key: "prep", type: :shell, run: "true"},
      %{key: "fo", type: :fan_out},
      %{key: "a", type: :shell, run: "true"},
      %{key: "b1", type: :agent, run: "first"},
      %{key: "b2", type: :agent, run: "second"},
      %{key: "c", type: :shell, run: "true"},
      %{key: "fi", type: :fan_in},
      %{key: "after", type: :shell, run: "true"}
    ]
  end

  @doc "The panel's edges, in edge order."
  def panel_edges do
    [
      %{from: "start", to: "prep"},
      %{from: "prep", to: "fo", on: :succeeded},
      %{from: "fo", to: "a"},
      %{from: "fo", to: "b1"},
      %{from: "fo", to: "c"},
      %{from: "a", to: "fi", on: :succeeded},
      %{from: "a", to: "fi", on: :failed},
      %{from: "b1", to: "b2", on: :succeeded},
      %{from: "b2", to: "b1", on: :failed, max_loops: 2},
      %{from: "b2", to: "fi", on: :succeeded},
      %{from: "c", to: "fi", on: :succeeded},
      %{from: "fi", to: "after", on: :succeeded},
      %{from: "fi", to: "prep", on: :failed},
      %{from: "after", to: "done", on: :succeeded}
    ]
  end

  @doc """
  The engine tests' `three` flow's nodes (RE437): `prep` → `fo` ⇉ `a` (shell), `b1` ⇄ `b2`
  (agents), `c` (shell) → `fi` → `done`, with `fi → report` on failed.
  """
  def three_nodes do
    [
      %{key: "prep", type: :shell, run: "true"},
      %{key: "fo", type: :fan_out},
      %{key: "a", type: :shell, run: "true"},
      %{key: "b1", type: :agent, run: "review", agent: "quality-reviewer"},
      %{key: "b2", type: :agent, run: "fix", agent: "final-fixer"},
      %{key: "c", type: :shell, run: "true"},
      %{key: "fi", type: :fan_in},
      %{key: "report", type: :shell, run: "true"}
    ]
  end

  @doc "The `three` flow's edges, in edge order."
  def three_edges do
    [
      %{from: "start", to: "prep"},
      %{from: "prep", to: "fo", on: :succeeded},
      %{from: "fo", to: "a"},
      %{from: "fo", to: "b1"},
      %{from: "fo", to: "c"},
      %{from: "a", to: "fi", on: :succeeded},
      %{from: "a", to: "fi", on: :failed},
      %{from: "b1", to: "fi", on: :succeeded},
      %{from: "b1", to: "b2", on: :failed, max_loops: 2},
      %{from: "b2", to: "b1", on: :succeeded},
      %{from: "c", to: "fi", on: :succeeded},
      %{from: "c", to: "fi", on: :failed},
      %{from: "fi", to: "done", on: :succeeded},
      %{from: "fi", to: "report", on: :failed},
      %{from: "report", to: "done", on: :succeeded}
    ]
  end

  @doc """
  The read-side tests' `region` flow's nodes (RE437 task 5, scenario 1):
  `prep` → `fo` ⇉ {`a`, `b1` ⇄ `b2`} → `fi` → `after` → `done`.
  """
  def region_nodes do
    [
      %{key: "prep", type: :shell, run: "true"},
      %{key: "fo", type: :fan_out},
      %{key: "a", type: :shell, run: "true"},
      %{key: "b1", type: :agent, run: "b1"},
      %{key: "b2", type: :agent, run: "b2"},
      %{key: "fi", type: :fan_in},
      %{key: "after", type: :shell, run: "true"}
    ]
  end

  @doc "The `region` flow's edges, in edge order."
  def region_edges do
    [
      %{from: "start", to: "prep"},
      %{from: "prep", to: "fo", on: :succeeded},
      %{from: "fo", to: "a"},
      %{from: "fo", to: "b1"},
      %{from: "a", to: "fi", on: :succeeded},
      %{from: "b1", to: "b2", on: :failed},
      %{from: "b2", to: "b1", on: :succeeded},
      %{from: "b1", to: "fi", on: :succeeded},
      %{from: "fi", to: "after", on: :succeeded},
      %{from: "after", to: "done", on: :succeeded}
    ]
  end

  @doc "Creates the `region` flow on `board`, owned by `stage`."
  def region_flow(board, stage) do
    {:ok, flow} =
      Hamaca.Flows.create_flow(board, %{
        key: "region",
        isolation: :shared_clean,
        stage_id: stage.id,
        nodes: region_nodes(),
        edges: region_edges()
      })

    flow
  end

  @doc """
  A running run on `card`'s `region` flow sitting on `fo`, with one `run_branch` row per
  `{branch, state, outcome}` in `specs`, at positions 0, 1, …. Returns `{run, branches}`.
  """
  def seed_region_run(card, specs) do
    run = Hamaca.Factory.insert(:run, card: card, flow_key: "region", status: :running, current_node: "fo")
    fan_out = Hamaca.Factory.insert(:node_execution, run: run, node: "fo")

    branches =
      specs
      |> Enum.with_index()
      |> Enum.map(fn {{key, state, outcome}, position} ->
        Hamaca.Factory.insert(:run_branch,
          run: run,
          fan_out_execution: fan_out,
          branch: key,
          position: position,
          state: state,
          outcome: outcome
        )
      end)

    {run, branches}
  end

  @doc "Create attrs for the panel flow (no `stage_id`)."
  def panel_attrs(overrides \\ %{}) do
    Map.merge(%{key: "panel", isolation: :shared_clean, nodes: panel_nodes(), edges: panel_edges()}, overrides)
  end

  @doc "The panel as a cast `%Schemas.Flow{}` (no database), for the pure region helpers."
  def panel_flow(nodes \\ panel_nodes(), edges \\ panel_edges()) do
    %Schemas.Flow{}
    |> Ecto.Changeset.cast(%{nodes: nodes, edges: edges}, [])
    |> Ecto.Changeset.cast_embed(:nodes)
    |> Ecto.Changeset.cast_embed(:edges)
    |> Ecto.Changeset.apply_changes()
  end

  @doc "Every edge but those from `from` to `to`."
  def drop_edges(edges, from, to), do: Enum.reject(edges, &(&1.from == from and &1.to == to))

  @doc "`nodes` with the node keyed `key` merged with `attrs`."
  def put_node(nodes, key, attrs), do: Enum.map(nodes, &if(&1.key == key, do: Map.merge(&1, attrs), else: &1))
end
