defmodule RelayWeb.BoardSettingsStageFlowsTest do
  @moduledoc """
  RE431 — Board Settings → Stages owns flows: each main-stage row carries its FLOW band (or the
  no-flow band, or the queue note), the derived PULLS FROM → WORKS IN → LANDS ON row, a direct
  On/Off toggle and a ⋯ menu. The Flows tab is gone; old `?section=flows` links land on Stages.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Flows
  alias Relay.Repo

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  defp stage_named(board, name), do: Enum.find(Boards.list_stages(board), &(&1.name == name and is_nil(&1.parent_id)))

  defp open_stages(conn, board) do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=stages")
    view
  end

  defp attr(view, selector, name) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  defp text(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  describe "navigation" do
    test "no link points at the Flows section, and the rail says flows moved into Stages",
         %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      refute has_element?(view, ~s(a[href$="section=flows"]))

      assert text(view, "#settings-rail #settings-flows-moved-note") ==
               "Flows moved into Stages — each stage row owns its flow."
    end

    test "an old ?section=flows link lands on Stages", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=flows")

      assert has_element?(view, "#stages-pane")
      refute has_element?(view, "#flows-pane")
    end
  end

  describe "the FLOW band" do
    test "the Code row carries its band: chip, meta, toggle and menu", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      flow = Flows.get_flow!(board, "code")
      view = open_stages(conn, board)

      row = "#stage-#{code.id}-row"
      assert has_element?(view, "#{row} #stage-#{code.id}-flow-band")

      assert has_element?(
               view,
               ~s(#{row} a#stage-#{code.id}-ai-flow[href="/board/#{board.slug}/flows/code"]),
               "code flow"
             )

      assert text(view, "#{row} #flow-#{flow.id}-meta") == "v1 · #{length(flow.nodes)} nodes"
      assert has_element?(view, ~s(#{row} #flow-#{flow.id}-toggle[aria-pressed="false"]))
      assert has_element?(view, "#{row} details#flow-#{flow.id}-menu")
    end

    test "the neighbours row is worked out from board order", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      spec = stage_named(board, "Spec")
      view = open_stages(conn, board)

      assert text(view, "#stage-#{code.id}-neighbours-pulls-from") == "Plan · Done"
      assert text(view, "#stage-#{code.id}-neighbours-works-in") == "Code"
      assert text(view, "#stage-#{code.id}-neighbours-lands-on") == "Review"
      assert text(view, "#stage-#{code.id}-neighbours-hint") =~ "worked out from board order"

      assert attr(view, "#stage-#{code.id}-neighbours-hint", "title") == [
               "Worked out from the board order — reorder stages to change it"
             ]

      assert text(view, "#stage-#{spec.id}-neighbours-pulls-from") == "Next up"
      assert text(view, "#stage-#{spec.id}-neighbours-works-in") == "Spec"
      assert text(view, "#stage-#{spec.id}-neighbours-lands-on") == "Spec · Review"
    end

    test "the toggle flips the flow directly, both ways", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      flow = Flows.get_flow!(board, "code")
      view = open_stages(conn, board)

      view |> element("#flow-#{flow.id}-toggle") |> render_click()
      assert Flows.get_flow!(board, "code").enabled == true
      assert has_element?(view, ~s(#flow-#{flow.id}-toggle[aria-pressed="true"]))
      assert text(view, "#stage-#{code.id}-flow-onoff") == "On"

      view |> element("#flow-#{flow.id}-toggle") |> render_click()
      assert Flows.get_flow!(board, "code").enabled == false
      assert text(view, "#stage-#{code.id}-flow-onoff") == "Off"
    end

    test "Delete flow is disabled while the flow is on", %{conn: conn, board: board} do
      {:ok, flow} = board |> Flows.get_flow!("code") |> Flows.enable_flow()
      view = open_stages(conn, board)

      assert has_element?(view, "li.menu-disabled #flow-#{flow.id}-delete[disabled]")
      assert text(view, "#flow-#{flow.id}-delete") =~ "turn it off first"
    end

    test "an off flow's Delete opens the confirm in its band and deletes it",
         %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      flow = Flows.get_flow!(board, "code")
      view = open_stages(conn, board)

      refute has_element?(view, "li.menu-disabled #flow-#{flow.id}-delete")
      view |> element("#flow-#{flow.id}-delete") |> render_click()
      assert has_element?(view, "#stage-#{code.id}-flow-band #flow-#{flow.id}-delete-confirm")

      view |> element("#flow-#{flow.id}-delete-cta") |> render_click()
      assert Flows.get_flow(board, "code") == nil
      assert has_element?(view, "#stage-#{code.id}-row #stage-#{code.id}-no-flow")
    end

    test "deleting a flow with a run in flight warns, then orphans the run",
         %{conn: conn, board: board} do
      flow = Flows.get_flow!(board, "code")
      run = insert(:run, flow_id: flow.id, status: :running)
      view = open_stages(conn, board)

      view |> element("#flow-#{flow.id}-delete") |> render_click()
      assert has_element?(view, "#flow-#{flow.id}-delete-midrun")

      view |> element("#flow-#{flow.id}-delete-cta") |> render_click()
      assert Repo.reload(run).flow_id == nil
    end

    test "Reset and the customized badge appear only once the flow is customized",
         %{conn: conn, board: board} do
      plan = Flows.get_flow!(board, "plan")
      view = open_stages(conn, board)

      refute has_element?(view, "#flow-#{plan.id}-reset")
      refute has_element?(view, "#flow-#{plan.id}-customized")

      {:ok, _} = Flows.save_definition(plan, %{isolation: :exclusive})
      view = open_stages(conn, board)

      assert has_element?(view, "#flow-#{plan.id}-reset")
      assert has_element?(view, "#flow-#{plan.id}-customized")

      view |> element("#flow-#{plan.id}-reset") |> render_click()
      assert has_element?(view, "#flow-#{plan.id}-reset-confirm")

      view |> element("#flow-#{plan.id}-reset-cta") |> render_click()
      reset = Flows.get_flow!(board, "plan")
      assert reset.isolation == :shared_clean
      assert reset.version == 3
    end

    test "the menu opens the editor and offers Copy to another stage", %{conn: conn, board: board} do
      flow = Flows.get_flow!(board, "code")
      view = open_stages(conn, board)

      assert has_element?(
               view,
               ~s(a#flow-#{flow.id}-open[href="/board/#{board.slug}/flows/code"]),
               "Open in flow editor"
             )

      assert has_element?(view, "#flow-#{flow.id}-copy", "Copy to another stage…")
    end
  end

  describe "rows without a flow" do
    test "a work stage offers Add flow; queues rest; review and done show nothing",
         %{conn: conn, board: board} do
      deploy = stage_named(board, "Deploy")
      view = open_stages(conn, board)

      assert has_element?(view, "#stage-#{deploy.id}-no-flow", "No flow — people work this stage by hand.")
      assert has_element?(view, "#stage-#{deploy.id}-add-flow", "+ Add flow")

      for name <- ["Backlog", "Next up"] do
        stage = stage_named(board, name)
        assert has_element?(view, "#stage-#{stage.id}-queue-note", "cards rest here")
        refute has_element?(view, "#stage-#{stage.id}-add-flow")
      end

      for name <- ["Review", "Done"] do
        stage = stage_named(board, name)

        for suffix <- ~w(flow-band no-flow queue-note) do
          refute has_element?(view, "#stage-#{stage.id}-#{suffix}")
        end
      end
    end

    test "with no stage before it the flow reads 'none' and can't be turned on",
         %{conn: conn, board: board} do
      for name <- ["Backlog", "Next up"], do: {:ok, _} = Boards.delete_stage(stage_named(board, name))
      spec = stage_named(board, "Spec")
      flow = Flows.get_flow!(board, "spec")
      view = open_stages(conn, board)

      assert text(view, "#stage-#{spec.id}-neighbours-pulls-from") == "none"
      assert has_element?(view, "#flow-#{flow.id}-toggle[disabled]")
    end
  end

  describe "live updates" do
    test "the band follows stage broadcasts", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      flow = Flows.get_flow!(board, "code")
      view = open_stages(conn, board)

      {:ok, _} = Boards.create_stage(board, %{name: "Triage", before: code})
      render(view)
      assert text(view, "#stage-#{code.id}-neighbours-pulls-from") == "Triage"

      {:ok, _} = Flows.enable_flow(flow)
      {:ok, _} = Boards.update_stage(Boards.get_stage(board, code.id), %{name: "Build"})
      render(view)
      assert has_element?(view, ~s(#flow-#{flow.id}-toggle[aria-pressed="true"]))
      assert text(view, "#stage-#{code.id}-neighbours-works-in") == "Build"
    end
  end

  test "an archived board refuses the toggle", %{conn: conn, board: board} do
    flow = Flows.get_flow!(board, "code")
    {:ok, _} = Boards.archive_board(board)
    view = open_stages(conn, board)

    render_click(view, "flow_toggle", %{"flow-id" => to_string(flow.id)})
    assert render(view) =~ "This board is archived (read-only)."
    assert Flows.get_flow!(board, "code").enabled == false
  end

  describe "design fidelity (card mockup A)" do
    test "the band, no-flow band, meta and menu carry the mockup's tokens", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      deploy = stage_named(board, "Deploy")
      flow = Flows.get_flow!(board, "code")
      view = open_stages(conn, board)

      [band_style] = attr(view, "#stage-#{code.id}-flow-band", "style")
      assert band_style =~ "color-mix(in oklab, var(--color-secondary) 4%, var(--color-base-100))"
      assert band_style =~ "color-mix(in oklab, var(--color-secondary) 18%, var(--color-base-100))"

      [label_style] = attr(view, "#stage-#{code.id}-flow-label", "style")
      assert label_style =~ "color-mix(in oklab, var(--color-secondary) 55%, var(--color-base-content))"

      assert has_element?(view, "#stage-#{deploy.id}-no-flow.border-dashed.border-base-300")
      assert has_element?(view, "#stage-#{deploy.id}-add-flow.btn.btn-sm.btn-outline")
      assert has_element?(view, "#flow-#{flow.id}-meta.font-mono")
      assert view |> attr("#flow-#{flow.id}-meta", "class") |> hd() =~ "text-[11px]"
      assert has_element?(view, "#flow-#{flow.id}-menu ul.menu.w-60")
    end
  end

  describe "Copy to another stage" do
    setup %{board: board} do
      {:ok, qa} = Boards.create_stage(board, %{name: "QA", category: :in_progress})
      %{qa: qa, flow: Flows.get_flow!(board, "code")}
    end

    defp open_copy(conn, board, flow) do
      view = open_stages(conn, board)
      view |> element("#flow-#{flow.id}-copy") |> render_click()
      view
    end

    defp option_names(view, selector) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#{selector} option")
      |> Enum.map(&LazyHTML.text/1)
    end

    test "8. the picker lists only the free work stages and previews the first key",
         %{conn: conn, board: board, flow: flow} do
      view = open_copy(conn, board, flow)

      assert text(view, "#flow-#{flow.id}-copy-panel") =~ "Copy the code flow to another stage"

      expected = Enum.map(Flows.assignable_stages(board, nil), & &1.name)
      assert expected == ["Deploy", "QA"]
      assert option_names(view, "#flow-#{flow.id}-copy-target") == expected
      assert text(view, "#flow-#{flow.id}-copy-key") == "code-deploy"
    end

    test "9. changing the target updates the key and submitting copies it, switched off",
         %{conn: conn, board: board, flow: flow, qa: qa} do
      view = open_copy(conn, board, flow)

      view |> element("#flow-#{flow.id}-copy-form") |> render_change(%{"copy" => %{"stage_id" => qa.id}})
      assert text(view, "#flow-#{flow.id}-copy-key") == "code-qa"

      view |> element("#flow-#{flow.id}-copy-form") |> render_submit()

      copy = Flows.get_flow(board, "code-qa")
      assert copy.stage_id == qa.id
      assert copy.enabled == false
      refute has_element?(view, "#flow-#{flow.id}-copy-panel")
      assert has_element?(view, "#stage-#{qa.id}-flow-band")
      assert has_element?(view, ~s(#flow-#{copy.id}-toggle[aria-pressed="false"]))
    end

    test "10. an occupied target is refused", %{conn: conn, board: board, flow: flow} do
      plan = stage_named(board, "Plan")
      view = open_copy(conn, board, flow)
      before = length(Flows.list_flows(board))

      render_submit(view, "flow_confirm_copy", %{
        "flow_id" => to_string(flow.id),
        "copy" => %{"stage_id" => to_string(plan.id)}
      })

      assert render(view) =~ "Pick a stage without a flow."
      assert length(Flows.list_flows(board)) == before
    end

    test "11. with every work stage holding a flow, Copy is disabled and says why",
         %{conn: conn, board: board, flow: flow, qa: qa} do
      {:ok, _} = Flows.copy_flow(flow, stage_named(board, "Deploy"))
      {:ok, _} = Flows.add_flow(qa, :blank)
      view = open_stages(conn, board)

      assert has_element?(view, "li.menu-disabled #flow-#{flow.id}-copy[disabled]")
      assert text(view, "#flow-#{flow.id}-copy") =~ "every work stage already has a flow"
    end
  end

  describe "+ Add flow" do
    setup %{board: board} do
      {:ok, qa} = Boards.create_stage(board, %{name: "QA", category: :in_progress})
      %{qa: qa}
    end

    defp neighbour_display_names(board, stage) do
      %{pulls_from: pulls_from, lands_on: lands_on} = Flows.neighbours(stage.id, Boards.list_stages(board))
      {Boards.stage_display_name(pulls_from), Boards.stage_display_name(lands_on)}
    end

    test "12. with every library flow on the board, the panel offers Blank and previews the neighbours",
         %{conn: conn, board: board, qa: qa} do
      view = open_stages(conn, board)
      view |> element("#stage-#{qa.id}-add-flow") |> render_click()

      assert text(view, "#stage-#{qa.id}-add-flow-panel") =~ "Add a flow to QA"

      refute has_element?(view, "#stage-#{qa.id}-add-source-default:not([disabled])")
      assert has_element?(view, "#stage-#{qa.id}-add-source-blank[checked]")

      {pulls_from, lands_on} = neighbour_display_names(board, qa)
      preview = text(view, "#stage-#{qa.id}-add-flow-preview")
      assert preview =~ pulls_from
      assert preview =~ lands_on
      assert preview =~ "It starts off"
    end

    test "13. submitting Blank puts a switched-off flow on the stage", %{conn: conn, board: board, qa: qa} do
      view = open_stages(conn, board)
      view |> element("#stage-#{qa.id}-add-flow") |> render_click()
      view |> element("#stage-#{qa.id}-add-flow-form") |> render_submit()

      flow = Flows.get_flow!(board, "qa")
      assert flow.stage_id == qa.id
      assert flow.enabled == false
      refute has_element?(view, "#stage-#{qa.id}-no-flow")
      assert has_element?(view, "#stage-#{qa.id}-flow-band")
      assert has_element?(view, ~s(#flow-#{flow.id}-toggle[aria-pressed="false"]))

      {pulls_from, lands_on} = neighbour_display_names(board, qa)
      assert text(view, "#stage-#{qa.id}-neighbours-pulls-from") == pulls_from
      assert text(view, "#stage-#{qa.id}-neighbours-lands-on") == lands_on
    end

    test "14. a deleted library flow can be re-added from the library", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, _} = board |> Flows.get_flow!("code") |> Flows.disable_flow()
      {:ok, _} = board |> Flows.get_flow!("code") |> Flows.delete_flow()

      view = open_stages(conn, board)
      view |> element("#stage-#{code.id}-add-flow") |> render_click()

      assert has_element?(view, "#stage-#{code.id}-add-source-default[checked]")
      assert option_names(view, "#stage-#{code.id}-add-default-key") == ["code"]

      view |> element("#stage-#{code.id}-add-flow-form") |> render_submit()

      flow = Flows.get_flow!(board, "code")
      assert flow.stage_id == code.id
      assert flow.enabled == false
      refute Flows.customized?(flow)
    end
  end

  test "15. an archived board refuses copy and add", %{conn: conn, board: board} do
    flow = Flows.get_flow!(board, "code")
    deploy = stage_named(board, "Deploy")
    {:ok, _} = Boards.archive_board(board)
    view = open_stages(conn, board)
    before = length(Flows.list_flows(board))

    pushes = [
      {"flow_copy", %{"flow-id" => to_string(flow.id)}},
      {"flow_confirm_copy", %{"flow_id" => to_string(flow.id), "copy" => %{"stage_id" => to_string(deploy.id)}}},
      {"flow_add", %{"stage-id" => to_string(deploy.id)}},
      {"flow_confirm_add", %{"stage_id" => to_string(deploy.id), "add" => %{"source" => "blank", "default_key" => ""}}}
    ]

    for {event, params} <- pushes do
      assert render_click(view, event, params) =~ "This board is archived (read-only)."
    end

    assert length(Flows.list_flows(board)) == before
  end

  describe "design fidelity — copy and add panels (card mockup A)" do
    test "16. the copy picker and add panel carry the mockup's classes", %{conn: conn, board: board} do
      flow = Flows.get_flow!(board, "code")
      deploy = stage_named(board, "Deploy")
      view = open_stages(conn, board)

      view |> element("#flow-#{flow.id}-copy") |> render_click()

      assert has_element?(
               view,
               "#flow-#{flow.id}-copy-panel.flex.flex-col.gap-2.rounded-\\[10px\\].border.border-base-300.bg-base-100.px-4.py-3.shadow-sm"
             )

      assert has_element?(view, "#flow-#{flow.id}-copy-submit.btn.btn-sm.btn-secondary", "Copy flow")
      assert has_element?(view, "#flow-#{flow.id}-copy-cancel.btn.btn-sm.btn-ghost")

      view |> element("#stage-#{deploy.id}-add-flow") |> render_click()

      assert has_element?(
               view,
               "#stage-#{deploy.id}-add-flow-panel.mt-2.rounded-lg.border.border-base-300.bg-base-100.p-3.shadow-sm"
             )

      assert has_element?(view, "#stage-#{deploy.id}-add-source-default.radio.radio-xs.radio-secondary")
      assert has_element?(view, "#stage-#{deploy.id}-add-source-blank.radio.radio-xs.radio-secondary")
      assert has_element?(view, "#stage-#{deploy.id}-add-flow-submit.btn.btn-sm.btn-secondary", "Add flow")
    end
  end

  describe "design fidelity — delete-stage panel (card mockup A)" do
    test "10. the delete-stage panel carries the mockup's error tints and daisyUI buttons",
         %{conn: conn, board: board} do
      deploy = stage_named(board, "Deploy")

      {:ok, ship} =
        Flows.create_flow(board, %{
          key: "ship",
          isolation: :shared_clean,
          stage_id: deploy.id,
          nodes: [],
          edges: [%{from: "start", to: "done"}]
        })

      {:ok, ship} = Flows.save_definition(ship, %{isolation: :exclusive})
      {:ok, ship} = Flows.save_definition(ship, %{isolation: :shared_clean})
      {:ok, _} = Flows.enable_flow(ship)

      view = open_stages(conn, board)
      view |> element("#stage-#{deploy.id}-delete") |> render_click()

      panel = "#stage-#{deploy.id}-delete-panel"
      [style] = attr(view, panel, "style")
      assert style =~ "color-mix(in oklab, var(--color-error) 5%, var(--color-base-100))"
      assert style =~ "color-mix(in oklab, var(--color-error) 35%, var(--color-base-100))"

      assert has_element?(view, "#{panel} .bg-error.text-error-content.rounded-full", "!")

      [title_style] = attr(view, "#stage-#{deploy.id}-delete-title", "style")
      assert title_style =~ "color-mix(in oklab, var(--color-error) 55%, var(--color-base-content))"

      assert has_element?(view, "#stage-#{deploy.id}-delete-flow code.font-mono", "ship")
      assert has_element?(view, "#stage-#{deploy.id}-delete-confirm.btn.btn-sm.btn-error")
      assert has_element?(view, "#stage-#{deploy.id}-delete-cancel.btn.btn-sm.btn-ghost")
    end
  end
end
