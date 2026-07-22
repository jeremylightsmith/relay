defmodule RelayWeb.FlowEditorLiveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Flows

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  test "mounts the editor for a flow key and shows the version chip", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/flows/code")
    assert has_element?(view, "#flow-editor-version-chip", "v1")
    assert has_element?(view, "#flow-graph")
  end

  test "the Code flow diagram distinguishes the two quality_review succeeded edges by their guard",
       %{conn: conn, board: board} do
    {:ok, view, html} = live(conn, ~p"/board/#{board.slug}/flows/code")
    _ = view
    # the loop-back and the advance no longer read as identical bare "succeeded"
    assert html =~ "succeeded · while tasks remain"
    assert html =~ "succeeded · all tasks done"
  end

  test "renders full-bleed (wide) chrome, not the narrow centered column", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/flows/code")
    # RLY-143: without `wide` the graph editor gets clipped to Layouts.app's default
    # mx-auto max-w-2xl centered column.
    refute has_element?(view, "main div.max-w-2xl")
    assert has_element?(view, "#top-bar-crumb-boards")
  end

  test "404s on an unknown flow key", %{conn: conn, board: board} do
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/board/#{board.slug}/flows/nope")
    assert to =~ "/board/#{board.slug}/settings"
  end

  test "opening a foreach flow does not corrupt the working copy with a spurious routing error", %{
    conn: conn,
    board: board
  } do
    {:ok, _flow} =
      Flows.create_flow(board, %{
        key: "loopy",
        isolation: :shared_clean,
        nodes: [
          %{key: "work", type: :agent, run: "a", foreach: "card.sub_tasks"},
          %{key: "after", type: :gate, run: "true"}
        ],
        edges: [
          %{from: "start", to: "work"},
          %{from: "work", to: "work", on: :succeeded, when: :foreach_remaining},
          %{from: "work", to: "after", on: :succeeded, when: :foreach_exhausted},
          %{from: "after", to: "done", on: :succeeded}
        ]
      })

    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/loopy")

    refute has_element?(view, "#flow-editor-errors")
  end

  test "mounts and renders the editor for a just-created scratch flow (nodes: [], start → done)",
       %{conn: conn, board: board} do
    [pulls, works, lands | _] = Boards.list_stages(board)

    {:ok, flow} =
      Flows.create_flow(board, %{
        key: "deploy-gate",
        isolation: :shared_clean,
        pulls_from_stage_id: pulls.id,
        works_in_stage_id: works.id,
        lands_on_stage_id: lands.id,
        nodes: [],
        edges: [%{from: "start", to: "done"}]
      })

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/flows/#{flow.key}")

    assert has_element?(view, "#flow-graph")
    assert has_element?(view, "#flow-editor-version-chip", "v1")
  end

  test "editing a trigger stage marks dirty and saves without a version bump", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    code = Flows.get_flow!(board, "code")
    other = Enum.find(board.stages, &(&1.id != code.pulls_from_stage_id))

    view
    |> element("#trigger-pulls-from")
    |> render_change(%{"stage_id" => to_string(other.id)})

    assert has_element?(view, "#flow-editor-unsaved-bar")

    view |> element("#flow-editor-save") |> render_click()
    # trigger-only change: no modal, saves directly, version stays v1
    assert has_element?(view, "#flow-editor-version-chip", "v1")
    assert Flows.get_flow!(board, "code").pulls_from_stage_id == other.id
  end

  test "saving a trigger change that collides with another enabled flow's pulls-from stage shows an inline error",
       %{conn: conn, board: board} do
    code = Flows.get_flow!(board, "code")
    spec = Flows.get_flow!(board, "spec")
    {:ok, code} = Flows.enable_flow(code)
    {:ok, spec} = Flows.enable_flow(spec)

    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")

    view
    |> element("#trigger-pulls-from")
    |> render_change(%{"stage_id" => to_string(spec.pulls_from_stage_id)})

    view |> element("#flow-editor-save") |> render_click()

    assert has_element?(view, "#flow-editor-errors", "another enabled flow already pulls from this stage")
    assert Flows.get_flow!(board, "code").pulls_from_stage_id == code.pulls_from_stage_id
  end

  test "editing then Save opens the confirm modal; confirm bumps to v2", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")

    # simulate a definition edit through the working copy (implement prompt) via the
    # low-level edit event the inspector (Task 4) will emit.
    render_hook(view, "edit_node_field", %{"key" => "implement", "field" => "run", "value" => "CHANGED"})

    view |> element("#flow-editor-save") |> render_click()
    assert has_element?(view, "#flow-save-modal", "Save as v2")

    view |> element("#flow-save-confirm") |> render_click()
    assert has_element?(view, "#flow-editor-version-chip", "v2")
    assert %Schemas.FlowVersion{} = Flows.get_version(Flows.get_flow!(board, "code"), 1)
    assert %Schemas.FlowVersion{nodes: nodes} = Flows.get_version(Flows.get_flow!(board, "code"), 2)
    assert Enum.any?(nodes, &(&1.key == "implement" and &1.run == "CHANGED"))
  end

  test "the save modal omits the mid-run note while mid_run_count is 0", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    render_hook(view, "edit_node_field", %{"key" => "implement", "field" => "run", "value" => "X"})
    view |> element("#flow-editor-save") |> render_click()
    refute has_element?(view, "#flow-save-modal-midrun")
  end

  test "selecting a node shows the inspector; Delete node is guarded while referenced", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")

    view |> element(~s([data-node="implement"])) |> render_click()
    assert has_element?(view, "#inspector-node-name")
    # implement is referenced by several edges → delete disabled + warning strip
    assert has_element?(view, "#inspector-delete-node[disabled]")
    assert has_element?(view, "#inspector-delete-guard", "Referenced by")
  end

  test "editing the run prompt in the inspector marks the flow dirty", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    view |> element(~s([data-node="implement"])) |> render_click()

    view
    |> element("#inspector-node-form")
    |> render_change(%{"field" => "run", "value" => "new prompt"})

    assert has_element?(view, "#flow-editor-unsaved-bar")
  end

  test "clicking a model chip in the inspector selects it (RLY-143 phx-value-v regression)", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    view |> element(~s([data-node="implement"])) |> render_click()

    view |> element("#inspector-model-opus") |> render_click()
    assert has_element?(view, "#flow-editor-unsaved-bar")

    view |> element("#flow-editor-save") |> render_click()
    view |> element("#flow-save-confirm") |> render_click()

    assert %Schemas.FlowVersion{nodes: nodes} = Flows.get_version(Flows.get_flow!(board, "code"), 2)
    assert Enum.any?(nodes, &(&1.key == "implement" and &1.model == "opus"))
  end

  test "clicking an effort chip in the inspector selects it (RLY-143 phx-value-v regression)", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    view |> element(~s([data-node="implement"])) |> render_click()

    # "implement" ships with effort: "high"
    view |> element("#inspector-effort-medium") |> render_click()
    assert has_element?(view, "#flow-editor-unsaved-bar")

    view |> element("#flow-editor-save") |> render_click()
    view |> element("#flow-save-confirm") |> render_click()

    assert %Schemas.FlowVersion{nodes: nodes} = Flows.get_version(Flows.get_flow!(board, "code"), 2)
    assert Enum.any?(nodes, &(&1.key == "implement" and &1.effort == "medium"))
  end

  test "deleting the start edge blocks save with an inline error naming the problem", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")

    # select the start edge's outcome chip then delete it via the toolbar
    render_hook(view, "delete_start_edge", %{})
    assert has_element?(view, "#flow-editor-errors", "exactly one edge must leave start")
    assert has_element?(view, "#flow-editor-save[disabled]")
  end

  test "add-node palette inserts a typed node with a unique key and selects it", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    view |> element(~s(#palette-shell)) |> render_click()
    assert has_element?(view, "#inspector-node-name")
    # a new shell-N node exists in the graph
    assert render(view) =~ "shell-"
  end

  test "selecting an edge shows the edge inspector; the max-loops stepper marks the flow dirty", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")

    # spec_review → implement (failed, max_loops: 3) is edge index 3
    view |> element(~s([data-edge="3"])) |> render_click()
    assert has_element?(view, "#inspector-edge-from", "spec_review")
    assert has_element?(view, "#inspector-edge-to", "implement")

    view |> element("#inspector-max-loops-inc") |> render_click()
    assert has_element?(view, "#flow-editor-unsaved-bar")
  end

  test "stepping MAX RETRIES below the minimum clears it to no-limit instead of an invalid 0", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    # "spec_review" has no max_retries set (nil == no limit, displayed as 0)
    view |> element(~s([data-node="spec_review"])) |> render_click()

    # stepping down from unset must stay unset, not introduce an invalid 0
    view |> element("#inspector-max-retries-dec") |> render_click()
    refute has_element?(view, "#flow-editor-unsaved-bar")

    view |> element("#inspector-max-retries-inc") |> render_click()
    assert has_element?(view, "#flow-editor-unsaved-bar")
    refute has_element?(view, "#flow-editor-errors")

    # stepping back down from 1 clears to no-limit rather than landing on 0
    view |> element("#inspector-max-retries-dec") |> render_click()
    refute has_element?(view, "#flow-editor-unsaved-bar")
  end

  test "stepping MAX LOOPS below the minimum clears it to no-limit instead of an invalid 0", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    # spec_review → implement (failed, max_loops: 3) is edge index 3
    view |> element(~s([data-edge="3"])) |> render_click()

    for _ <- 1..3, do: view |> element("#inspector-max-loops-dec") |> render_click()
    # 3 -> 2 -> 1 -> nil: dirty (differs from the shipped default of 3) but not invalid
    assert has_element?(view, "#flow-editor-unsaved-bar")
    refute has_element?(view, "#flow-editor-errors")
    refute has_element?(view, "#flow-editor-save[disabled]")

    # a further decrement from unset stays unset, never reaching 0
    view |> element("#inspector-max-loops-dec") |> render_click()
    refute has_element?(view, "#flow-editor-errors")
  end

  test "the edge inspector's WHEN control shows the guard and edits it (set, then clear)", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")

    # quality_review → sync (succeeded, when: foreach_exhausted) is edge index 7
    view |> element(~s([data-edge="7"])) |> render_click()
    assert has_element?(view, "#inspector-edge-when")
    assert has_element?(view, "#inspector-edge-when option[value='foreach_exhausted'][selected]")

    # change the guard to the other value → dirty + reflects the choice
    view
    |> element("#inspector-edge-when-form")
    |> render_change(%{"value" => "foreach_remaining"})

    assert has_element?(view, "#flow-editor-unsaved-bar")
    assert has_element?(view, "#inspector-edge-when option[value='foreach_remaining'][selected]")

    # clear the guard to (none) → the empty option is selected
    view
    |> element("#inspector-edge-when-form")
    |> render_change(%{"value" => ""})

    assert has_element?(view, "#inspector-edge-when option[value=''][selected]")
  end

  test "editing another field on a guarded edge preserves its WHEN guard (2b regression)", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")

    # quality_review → implement (succeeded, when: foreach_remaining) is edge index 6
    view |> element(~s([data-edge="6"])) |> render_click()
    assert has_element?(view, "#inspector-edge-when option[value='foreach_remaining'][selected]")

    # step an UNRELATED field (MAX LOOPS) and save through the confirm modal
    view |> element("#inspector-max-loops-inc") |> render_click()
    view |> element("#flow-editor-save") |> render_click()
    view |> element("#flow-save-confirm") |> render_click()

    # the saved v2 edge still carries its foreach_remaining guard — not dropped
    assert %Schemas.FlowVersion{edges: edges} = Flows.get_version(Flows.get_flow!(board, "code"), 2)

    assert Enum.any?(edges, fn e ->
             e.from == "quality_review" and e.to == "implement" and
               e.on == :succeeded and e.when == :foreach_remaining and e.max_loops == 1
           end)
  end

  test "Delete edge in the inspector removes the selected edge", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    count_before = count_edges(render(view))

    view |> element(~s([data-edge="3"])) |> render_click()
    view |> element("#inspector-delete-edge") |> render_click()

    assert has_element?(view, "#flow-editor-unsaved-bar")
    assert count_edges(render(view)) == count_before - 1
  end

  test "Connect edge: selecting two nodes creates a new succeeded edge", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    count_before = count_edges(render(view))

    view |> element("#toolbar-connect-edge") |> render_click()
    view |> element(~s([data-node="branch"])) |> render_click()
    view |> element(~s([data-node="merge"])) |> render_click()

    assert has_element?(view, "#flow-editor-unsaved-bar")
    assert count_edges(render(view)) == count_before + 1
  end

  test "Connect edge: a second toolbar click cancels connect mode", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")

    view |> element("#toolbar-connect-edge") |> render_click()
    assert has_element?(view, "#toolbar-connect-edge", "Cancel")

    view |> element("#toolbar-connect-edge") |> render_click()
    refute has_element?(view, "#toolbar-connect-edge", "Cancel")
  end

  test "Connect edge: pressing Esc cancels connect mode", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")

    view |> element("#toolbar-connect-edge") |> render_click()
    assert has_element?(view, "#toolbar-connect-edge", "Cancel")

    view |> element("#flow-editor-canvas") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#toolbar-connect-edge", "Cancel")
  end

  test "renaming a node rewrites its key and every edge endpoint referencing it", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    view |> element(~s([data-node="branch"])) |> render_click()

    view
    |> element("#inspector-node-rename-form")
    |> render_change(%{"value" => "branch2"})

    assert has_element?(view, ~s([data-node="branch2"]))
    refute has_element?(view, ~s([data-node="branch"]))
  end

  test "a stale rename event (old key no longer present) is a no-op and doesn't corrupt selection", %{
    conn: conn,
    board: board
  } do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    view |> element(~s([data-node="branch"])) |> render_click()

    # simulate an in-flight keystroke event whose hidden "key" field is stale (the client
    # fired before the previous rename's patch landed) — no node is keyed "does-not-exist"
    render_hook(view, "rename_node", %{"key" => "does-not-exist", "value" => "zzz"})

    # no rename happened, and selection/inspector must still render safely
    refute has_element?(view, ~s([data-node="zzz"]))
    assert has_element?(view, ~s([data-node="branch"]))
    assert has_element?(view, "#inspector-node-name")
  end

  test "renaming a node to an empty key is blocked inline and disables Save", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    view |> element(~s([data-node="branch"])) |> render_click()

    view
    |> element("#inspector-node-rename-form")
    |> render_change(%{"value" => ""})

    assert has_element?(view, "#flow-editor-errors")
    assert has_element?(view, "#flow-editor-save[disabled]")
  end

  test "renaming a node to a reserved sentinel name is blocked inline and disables Save", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    view |> element(~s([data-node="branch"])) |> render_click()

    view
    |> element("#inspector-node-rename-form")
    |> render_change(%{"value" => "done"})

    assert has_element?(view, "#flow-editor-errors")
    assert has_element?(view, "#flow-editor-save[disabled]")
  end

  test "Connect edge: connecting a node to done creates an edge landing on done", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    count_before = count_edges(render(view))

    view |> element("#toolbar-connect-edge") |> render_click()
    view |> element(~s([data-node="branch"])) |> render_click()
    assert has_element?(view, "#flow-node-done")

    view |> element("#flow-node-done") |> render_click()

    assert count_edges(render(view)) == count_before + 1
    assert has_element?(view, "#inspector-edge-to", "done")
  end

  test "Delete node in the inspector removes an unreferenced node", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    view |> element("#palette-shell") |> render_click()
    view |> element("#inspector-delete-node") |> render_click()
    refute render(view) =~ ~s(data-node="shell-1")
  end

  test "a customized default flow shows the diff affordance; View diff lists the changed node", %{
    conn: conn,
    board: board
  } do
    {:ok, _flow} =
      Flows.save_definition(Flows.get_flow!(board, "code"), %{
        nodes: bump_implement_run(Flows.get_flow!(board, "code"))
      })

    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    assert has_element?(view, "#flow-diff-affordance", "differ from the shipped default")

    view |> element("#flow-diff-view") |> render_click()
    assert has_element?(view, "#flow-diff-modal", "implement")
  end

  test "Reset to default restores the definition and bumps the version", %{conn: conn, board: board} do
    {:ok, _} =
      Flows.save_definition(Flows.get_flow!(board, "code"), %{
        nodes: bump_implement_run(Flows.get_flow!(board, "code"))
      })

    {:ok, view, _} = live(conn, ~p"/board/#{board.slug}/flows/code")
    view |> element("#flow-diff-reset") |> render_click()
    view |> element("#flow-reset-confirm") |> render_click()

    refute has_element?(view, "#flow-diff-affordance")
    refute Flows.customized?(Flows.get_flow!(board, "code"))
  end

  defp count_edges(html), do: ~r/data-edge="\d+"/ |> Regex.scan(html) |> length()

  # helper: return the code flow's nodes with implement.run changed (as attr maps)
  defp bump_implement_run(flow) do
    Enum.map(flow.nodes, fn n ->
      base = Map.take(n, [:key, :type, :run, :model, :effort, :max_retries, :timeout_minutes, :foreach])
      if n.key == "implement", do: %{base | run: "CUSTOM"}, else: base
    end)
  end
end
