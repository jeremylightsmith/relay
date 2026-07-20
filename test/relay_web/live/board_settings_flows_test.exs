defmodule RelayWeb.BoardSettingsFlowsTest do
  use RelayWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Flows
  alias Relay.Repo
  alias Schemas.Flow

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  defp flow(board, key), do: Flows.get_flow!(board, key)

  defp open_flows(conn, board) do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=flows")
    view
  end

  defp open_new_flow(conn, board) do
    view = open_flows(conn, board)
    view |> element("#new-flow-button") |> render_click()
    view
  end

  defp stage_ids(board) do
    [pulls, works, lands | _] = Boards.list_stages(board)
    %{pulls: pulls.id, works: works.id, lands: lands.id}
  end

  describe "navigation" do
    test "rail and mobile strip both carry a Flows entry that opens the pane",
         %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      assert has_element?(view, "#settings-nav-flows", "Flows")
      assert has_element?(view, "#settings-tab-flows", "Flows")
      refute has_element?(view, "#flows-pane")

      view |> element("#settings-nav-flows") |> render_click()
      assert has_element?(view, "#flows-pane h1", "Flows")
      refute has_element?(view, "#stages-pane")

      view |> element("#settings-nav-stages") |> render_click()
      refute has_element?(view, "#flows-pane")

      view |> element("#settings-tab-flows") |> render_click()
      assert has_element?(view, "#flows-pane")
    end

    test "the header carries no version language but does carry the + New flow button",
         %{conn: conn, board: board} do
      view = open_flows(conn, board)

      assert has_element?(view, "#flows-pane", "A flow is the automation attached to a stage transition")
      refute render(view) =~ "versioned"
      assert has_element?(view, "#new-flow-button", "New flow")
    end
  end

  describe "rows" do
    test "lists the three seeded flows with node counts, trigger chips, badges, and off toggles",
         %{conn: conn, board: board} do
      spec = flow(board, "spec")
      plan = flow(board, "plan")
      code = flow(board, "code")
      view = open_flows(conn, board)

      assert has_element?(view, "#flow-row-#{spec.id}", "Spec")
      assert has_element?(view, "#flow-row-#{plan.id}", "Plan")
      assert has_element?(view, "#flow-row-#{code.id}", "Code")

      assert has_element?(view, "#flow-#{spec.id}-nodes-count", "1 node")
      assert has_element?(view, "#flow-#{code.id}-nodes-count", "18 nodes")

      assert has_element?(view, "#flow-#{spec.id}-trigger", "Next up")
      assert has_element?(view, "#flow-#{spec.id}-trigger", "Spec:Review")
      assert has_element?(view, "#flow-#{plan.id}-trigger", "Spec:Done")
      assert has_element?(view, "#flow-#{plan.id}-trigger", "Plan:Done")
      assert has_element?(view, "#flow-#{code.id}-trigger", "Review")

      assert has_element?(view, "#flow-#{spec.id}-isolation", "shared_clean")
      assert has_element?(view, "#flow-#{code.id}-isolation", "exclusive")
      assert has_element?(view, "#flows-legend", "fresh checkout each")

      assert has_element?(view, "#flow-#{spec.id}-toggle[aria-pressed='false']")
      refute has_element?(view, "#flow-#{spec.id}-customized")
    end

    test "seeded defaults carry no customized affix; a hand-customized flow does",
         %{conn: conn, board: board} do
      plan = flow(board, "plan")

      {:ok, plan} =
        Flows.update_flow(plan, %{
          nodes: [%{key: "write_plan", type: :agent, run: "custom run", max_retries: 3}],
          edges: [%{from: "start", to: "write_plan"}, %{from: "write_plan", to: "done", on: :succeeded}]
        })

      view = open_flows(conn, board)
      assert has_element?(view, "#flow-#{plan.id}-customized", "customized")
    end

    test "a flow with a missing trigger stage shows a warning chip and a disabled toggle",
         %{conn: conn, board: board} do
      {:ok, spec} = Flows.update_flow(flow(board, "spec"), %{pulls_from_stage_id: nil})
      view = open_flows(conn, board)

      assert has_element?(view, "#flow-#{spec.id}-trigger", "missing stage")
      assert has_element?(view, "#flow-#{spec.id}-toggle[disabled]")
    end

    test "renaming a trigger stage updates the chips live", %{conn: conn, board: board} do
      next_up = Enum.find(board.stages, &(&1.name == "Next up"))
      spec = flow(board, "spec")
      view = open_flows(conn, board)

      {:ok, _stage} = Boards.update_stage(next_up, %{name: "Inbox"})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#flow-#{spec.id}-trigger", "Inbox")
    end
  end

  describe "first-run, empty, and note states" do
    test "the first-run banner shows while every flow is disabled and names the seeded flows",
         %{conn: conn, board: board} do
      view = open_flows(conn, board)

      assert has_element?(view, "#flows-first-run", "Flows are off until you turn them on")
      assert has_element?(view, "#flows-first-run", "Code, Plan and Spec")
    end

    test "the first-run banner names only the flows Relay ships, not user-created ones",
         %{conn: conn, board: board} do
      ids = stage_ids(board)

      {:ok, _created} =
        Flows.create_flow(board, %{
          "key" => "smoke-gate",
          "isolation" => "shared_clean",
          "pulls_from_stage_id" => ids.pulls,
          "works_in_stage_id" => ids.works,
          "lands_on_stage_id" => ids.lands,
          "nodes" => [],
          "edges" => [%{"from" => "start", "to" => "done"}]
        })

      view = open_flows(conn, board)

      # the user's flow is on the board …
      assert has_element?(view, "#flows-table", "Smoke gate")
      # … but the banner still describes only what Relay ships
      assert has_element?(view, "#flows-first-run", "Code, Plan and Spec")
      refute has_element?(view, "#flows-first-run", "Smoke gate")
    end

    test "the first-run banner is suppressed when no shipped flow is left on the board",
         %{conn: conn, board: board} do
      ids = stage_ids(board)

      {:ok, _created} =
        Flows.create_flow(board, %{
          "key" => "smoke-gate",
          "isolation" => "shared_clean",
          "pulls_from_stage_id" => ids.pulls,
          "works_in_stage_id" => ids.works,
          "lands_on_stage_id" => ids.lands,
          "nodes" => [],
          "edges" => [%{"from" => "start", "to" => "done"}]
        })

      Repo.delete_all(from f in Flow, where: f.board_id == ^board.id and f.key in ["code", "plan", "spec"])

      view = open_flows(conn, board)

      # the page renders, the user's flow is listed, and no false "ships with" sentence
      assert has_element?(view, "#flows-table", "Smoke gate")
      refute has_element?(view, "#flows-first-run")
    end

    test "the footer cutover note is present", %{conn: conn, board: board} do
      view = open_flows(conn, board)

      assert has_element?(view, "#flows-footer-note", "Disabling a flow is a cutover")
    end

    test "a board with no flow rows shows the empty state", %{conn: conn, board: board} do
      Repo.delete_all(from f in Flow, where: f.board_id == ^board.id)
      view = open_flows(conn, board)

      assert has_element?(view, "#flows-empty", "No flows on this board yet")
      assert has_element?(view, "#flows-empty", "RLY-136")
      refute has_element?(view, "#flows-table")
      refute has_element?(view, "#flows-first-run")
    end
  end

  describe "enable/disable cutover confirm" do
    test "toggle opens the enable confirm; cancel persists nothing",
         %{conn: conn, board: board} do
      spec = flow(board, "spec")
      view = open_flows(conn, board)

      view |> element("#flow-#{spec.id}-toggle") |> render_click()

      assert has_element?(view, "#flow-#{spec.id}-confirm", "Turn on the Spec flow?")
      assert has_element?(view, "#flow-#{spec.id}-confirm", "handed to the AI automatically")
      refute has_element?(view, "#flow-#{spec.id}-confirm", "bin/relay watch")
      refute has_element?(view, "#flow-#{spec.id}-confirm", "relay_config.json")
      assert has_element?(view, "#flow-#{spec.id}-toggle[aria-pressed='false']")
      refute Flows.get_flow!(board, "spec").enabled

      view |> element("#flow-#{spec.id}-confirm-cancel") |> render_click()

      refute has_element?(view, "#flow-#{spec.id}-confirm")
      refute Flows.get_flow!(board, "spec").enabled
    end

    test "confirming enables; the disable confirm carries the hand-back line; confirming disables",
         %{conn: conn, board: board} do
      spec = flow(board, "spec")
      view = open_flows(conn, board)

      view |> element("#flow-#{spec.id}-toggle") |> render_click()
      view |> element("#flow-#{spec.id}-confirm-cta") |> render_click()

      assert Flows.get_flow!(board, "spec").enabled
      assert has_element?(view, "#flow-#{spec.id}-toggle[aria-pressed='true']")
      refute has_element?(view, "#flow-#{spec.id}-confirm")
      refute has_element?(view, "#flows-first-run")

      view |> element("#flow-#{spec.id}-toggle") |> render_click()

      assert has_element?(view, "#flow-#{spec.id}-confirm", "Turn off the Spec flow?")
      assert has_element?(view, "#flow-#{spec.id}-confirm", "wait for a human instead")
      assert has_element?(view, "#flow-#{spec.id}-confirm", "Turn the flow back on")
      refute has_element?(view, "#flow-#{spec.id}-confirm", "re-add this stage's entry")
      refute has_element?(view, "#flow-#{spec.id}-confirm", "relay_config.json")

      view |> element("#flow-#{spec.id}-confirm-cta") |> render_click()

      refute Flows.get_flow!(board, "spec").enabled
      assert has_element?(view, "#flow-#{spec.id}-toggle[aria-pressed='false']")
    end

    test "an enable conflict surfaces as an error flash naming the reason",
         %{conn: conn, board: board} do
      spec = flow(board, "spec")
      {:ok, _} = Flows.enable_flow(spec)

      {:ok, rival} =
        Flows.create_flow(board, %{
          key: "rival",
          isolation: :shared_clean,
          pulls_from_stage_id: spec.pulls_from_stage_id,
          works_in_stage_id: spec.works_in_stage_id,
          lands_on_stage_id: spec.lands_on_stage_id,
          nodes: [%{key: "n", type: :agent, run: "x"}],
          edges: [%{from: "start", to: "n"}, %{from: "n", to: "done", on: :succeeded}]
        })

      view = open_flows(conn, board)
      view |> element("#flow-#{rival.id}-toggle") |> render_click()
      view |> element("#flow-#{rival.id}-confirm-cta") |> render_click()

      assert render(view) =~ "another enabled flow already pulls from this stage"
      refute Flows.get_flow!(board, "rival").enabled
      assert has_element?(view, "#flow-#{rival.id}-toggle[aria-pressed='false']")
    end

    test "an archived board rejects the toggle as read-only", %{conn: conn, board: board} do
      spec = flow(board, "spec")
      {:ok, _} = Boards.archive_board(board)
      view = open_flows(conn, board)

      view |> element("#flow-#{spec.id}-toggle") |> render_click()

      assert render(view) =~ "archived (read-only)"
      refute has_element?(view, "#flow-#{spec.id}-confirm")
    end
  end

  describe "kebab actions" do
    test "the flow row's Edit item links to the full-page editor", %{conn: conn, board: board} do
      view = open_flows(conn, board)
      code = flow(board, "code")

      assert has_element?(
               view,
               ~s(a#flow-#{code.id}-edit[href="/board/#{board.slug}/flows/code"])
             )
    end

    test "the flow row meta line shows the version", %{conn: conn, board: board} do
      view = open_flows(conn, board)
      code = flow(board, "code")
      assert has_element?(view, "#flow-#{code.id}-nodes-count", "v#{code.version}")
    end

    test "Duplicate adds a disabled customized copy with no Reset item",
         %{conn: conn, board: board} do
      spec = flow(board, "spec")
      view = open_flows(conn, board)

      view |> element("#flow-#{spec.id}-duplicate") |> render_click()

      copy = Flows.get_flow!(board, "spec-copy")
      refute copy.enabled
      assert has_element?(view, "#flow-row-#{copy.id}", "Spec copy")
      assert has_element?(view, "#flow-#{copy.id}-customized", "customized")
      assert has_element?(view, "#flow-#{copy.id}-toggle[aria-pressed='false']")
      refute has_element?(view, "#flow-#{copy.id}-reset")
    end

    test "enabling a duplicate that pulls from the same stage surfaces the conflict (AC 3)",
         %{conn: conn, board: board} do
      spec = flow(board, "spec")
      {:ok, _} = Flows.enable_flow(spec)
      view = open_flows(conn, board)

      view |> element("#flow-#{spec.id}-duplicate") |> render_click()
      copy = Flows.get_flow!(board, "spec-copy")

      view |> element("#flow-#{copy.id}-toggle") |> render_click()
      view |> element("#flow-#{copy.id}-confirm-cta") |> render_click()

      assert render(view) =~ "another enabled flow already pulls from this stage"
      refute Flows.get_flow!(board, "spec-copy").enabled
    end

    test "Reset to default shows only for customized library flows, confirms, and restores the default",
         %{conn: conn, board: board} do
      plan = flow(board, "plan")

      {:ok, plan} =
        Flows.update_flow(plan, %{
          nodes: [%{key: "write_plan", type: :agent, run: "custom run", max_retries: 3}],
          edges: [%{from: "start", to: "write_plan"}, %{from: "write_plan", to: "done", on: :succeeded}]
        })

      view = open_flows(conn, board)

      spec = flow(board, "spec")
      refute has_element?(view, "#flow-#{spec.id}-reset")
      assert has_element?(view, "#flow-#{plan.id}-reset", "Reset to default")

      view |> element("#flow-#{plan.id}-reset") |> render_click()
      assert has_element?(view, "#flow-#{plan.id}-reset-confirm", "customizations are overwritten")
      assert Flows.customized?(Flows.get_flow!(board, "plan"))

      view |> element("#flow-#{plan.id}-reset-cancel") |> render_click()
      refute has_element?(view, "#flow-#{plan.id}-reset-confirm")
      assert Flows.customized?(Flows.get_flow!(board, "plan"))

      view |> element("#flow-#{plan.id}-reset") |> render_click()
      view |> element("#flow-#{plan.id}-reset-cta") |> render_click()

      refute Flows.customized?(Flows.get_flow!(board, "plan"))
      refute has_element?(view, "#flow-#{plan.id}-customized")
      refute has_element?(view, "#flow-#{plan.id}-reset")
      refute has_element?(view, "#flow-#{plan.id}-reset-confirm")
    end

    test "an archived board rejects Duplicate as read-only", %{conn: conn, board: board} do
      spec = flow(board, "spec")
      {:ok, _} = Boards.archive_board(board)
      view = open_flows(conn, board)

      view |> element("#flow-#{spec.id}-duplicate") |> render_click()

      assert render(view) =~ "archived (read-only)"
      assert Flows.get_flow(board, "spec-copy") == nil
    end
  end

  describe "+ New flow button (RLY-158)" do
    test "the button matches the artboard's placement, glyph and fill",
         %{conn: conn, board: board} do
      view = open_flows(conn, board)

      # docs/designs/Relay Flows.dc.html line 74 — primary-blue fill, 8px radius,
      # 9px 15px padding, 13px/600 label, with a 15px "+" glyph before "New flow".
      button =
        view
        |> element("#new-flow-button")
        |> render()

      assert button =~ "background:oklch(0.60 0.14 250)"
      assert button =~ "color:oklch(1 0 0)"
      assert button =~ "border-radius:8px"
      assert button =~ "padding:9px 15px"
      assert button =~ "font-size:13px"
      assert button =~ "font-weight:600"
      assert button =~ "font-size:15px;line-height:1"
      assert button =~ "New flow"

      # …in the artboard's right-hand header column (lines 63-72).
      assert has_element?(view, "#flows-header-actions #new-flow-button")
      assert render(view) =~ "align-items:flex-end;gap:10px;flex:0 0 auto;margin-top:4px;"
    end

    test "the button renders on a board with no flows at all", %{conn: conn, board: board} do
      Repo.delete_all(from f in Flow, where: f.board_id == ^board.id)

      view = open_flows(conn, board)

      assert has_element?(view, "#flows-empty")
      assert has_element?(view, "#new-flow-button")
    end

    test "an archived board does not render the button", %{conn: conn, board: board} do
      {:ok, _} = Boards.archive_board(board)

      view = open_flows(conn, board)

      assert has_element?(view, "#flows-pane")
      refute has_element?(view, "#new-flow-button")
    end

    test "an archived board shows a static read-only banner explaining why the button is gone",
         %{conn: conn, board: board} do
      {:ok, _} = Boards.archive_board(board)

      view = open_flows(conn, board)

      assert has_element?(view, "#flows-read-only-banner")
      assert render(view) =~ "archived (read-only)"
    end

    test "an unarchived board renders no read-only banner", %{conn: conn, board: board} do
      view = open_flows(conn, board)

      refute has_element?(view, "#flows-read-only-banner")
    end
  end

  describe "creating a flow from scratch (RLY-158)" do
    test "clicking the button opens the panel with the key prefilled and isolation defaulted",
         %{conn: conn, board: board} do
      view = open_new_flow(conn, board)

      assert has_element?(view, "#new-flow-form")
      assert has_element?(view, "#new-flow-key[value='new-flow']")
      assert has_element?(view, "#new-flow-pulls-from")
      assert has_element?(view, "#new-flow-works-in")
      assert has_element?(view, "#new-flow-lands-on")
      assert has_element?(view, "#new-flow-isolation option[value='shared_clean'][selected]")
    end

    test "the pickers offer sub-lane stages, not just top-level ones",
         %{conn: conn, board: board} do
      view = open_new_flow(conn, board)

      assert has_element?(view, "#new-flow-pulls-from", "Spec:Review")
    end

    test "creating a flow persists it disabled and navigates to the editor",
         %{conn: conn, board: board} do
      view = open_new_flow(conn, board)
      ids = stage_ids(board)

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#new-flow-form", %{
                 "flow" => %{
                   "key" => "deploy-gate",
                   "isolation" => "shared_clean",
                   "pulls_from_stage_id" => to_string(ids.pulls),
                   "works_in_stage_id" => to_string(ids.works),
                   "lands_on_stage_id" => to_string(ids.lands)
                 }
               })
               |> render_submit()

      assert to == "/board/#{board.slug}/flows/deploy-gate"

      created = Flows.get_flow!(board, "deploy-gate")
      refute created.enabled
      assert created.version == 1
      assert created.nodes == []
      assert [%{from: "start", to: "done", on: nil}] = created.edges
      assert created.pulls_from_stage_id == ids.pulls
      assert created.works_in_stage_id == ids.works
      assert created.lands_on_stage_id == ids.lands
    end

    test "the created flow's row shows 0 nodes and an off toggle",
         %{conn: conn, board: board} do
      view = open_new_flow(conn, board)
      ids = stage_ids(board)

      view
      |> form("#new-flow-form", %{
        "flow" => %{
          "key" => "deploy-gate",
          "isolation" => "shared_clean",
          "pulls_from_stage_id" => to_string(ids.pulls),
          "works_in_stage_id" => to_string(ids.works),
          "lands_on_stage_id" => to_string(ids.lands)
        }
      })
      |> render_submit()

      created = Flows.get_flow!(board, "deploy-gate")
      view = open_flows(conn, board)

      assert has_element?(view, "#flow-#{created.id}-nodes-count", "0 nodes")
      assert has_element?(view, "#flow-#{created.id}-toggle[aria-pressed='false']")
    end

    test "a blank trigger stage keeps the panel open with an inline error",
         %{conn: conn, board: board} do
      view = open_new_flow(conn, board)
      ids = stage_ids(board)

      html =
        view
        |> form("#new-flow-form", %{
          "flow" => %{
            "key" => "deploy-gate",
            "isolation" => "shared_clean",
            "pulls_from_stage_id" => "",
            "works_in_stage_id" => to_string(ids.works),
            "lands_on_stage_id" => to_string(ids.lands)
          }
        })
        |> render_submit()

      assert has_element?(view, "#new-flow-form")
      assert html =~ "is required"
      assert Flows.get_flow(board, "deploy-gate") == nil
    end

    test "a duplicate key keeps the panel open and preserves the stage selections",
         %{conn: conn, board: board} do
      view = open_new_flow(conn, board)
      ids = stage_ids(board)

      html =
        view
        |> form("#new-flow-form", %{
          "flow" => %{
            "key" => "spec",
            "isolation" => "shared_clean",
            "pulls_from_stage_id" => to_string(ids.pulls),
            "works_in_stage_id" => to_string(ids.works),
            "lands_on_stage_id" => to_string(ids.lands)
          }
        })
        |> render_submit()

      assert has_element?(view, "#new-flow-form")
      assert html =~ "has already been taken"
      assert has_element?(view, "#new-flow-pulls-from option[value='#{ids.pulls}'][selected]")
      assert has_element?(view, "#new-flow-works-in option[value='#{ids.works}'][selected]")
      assert has_element?(view, "#new-flow-lands-on option[value='#{ids.lands}'][selected]")
    end

    test "a malformed key is rejected inline", %{conn: conn, board: board} do
      view = open_new_flow(conn, board)
      ids = stage_ids(board)

      html =
        view
        |> form("#new-flow-form", %{
          "flow" => %{
            "key" => "Deploy Gate!",
            "isolation" => "shared_clean",
            "pulls_from_stage_id" => to_string(ids.pulls),
            "works_in_stage_id" => to_string(ids.works),
            "lands_on_stage_id" => to_string(ids.lands)
          }
        })
        |> render_submit()

      assert has_element?(view, "#new-flow-form")
      assert html =~ "must be lowercase letters, numbers and dashes"
    end

    test "cancel closes the panel without creating anything", %{conn: conn, board: board} do
      view = open_new_flow(conn, board)

      view |> element("#new-flow-cancel") |> render_click()

      refute has_element?(view, "#new-flow-form")
      assert Flows.get_flow(board, "new-flow") == nil
    end

    test "an archived board rejects flow_create as read-only", %{conn: conn, board: board} do
      {:ok, _} = Boards.archive_board(board)
      view = open_flows(conn, board)

      render_click(view, "flow_create", %{
        "flow" => %{
          "key" => "sneaky",
          "isolation" => "shared_clean",
          "pulls_from_stage_id" => "1",
          "works_in_stage_id" => "1",
          "lands_on_stage_id" => "1"
        }
      })

      assert render(view) =~ "archived (read-only)"
      assert Flows.get_flow(board, "sneaky") == nil
    end
  end
end
