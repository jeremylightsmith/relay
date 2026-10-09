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

  # Deploy is the default board's one flow-free work stage (RE429: one flow per stage).
  defp deploy_id(board), do: Enum.find(Boards.list_stages(board), &(&1.name == "Deploy")).id

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
      assert has_element?(view, "#flow-#{code.id}-nodes-count", "21 nodes")

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

    # RE237: the knob is ink on the track's fill, so it must come from a `-content` token (pinned
    # light in both themes), never from `base-100` — that is a surface token, and in dark it
    # resolves to 0.26, punching a near-black disc into the 0.65 blue ON track.
    test "the toggle knob is drawn in a -content ink, not in the base-100 surface",
         %{conn: conn, board: board} do
      spec = flow(board, "spec")
      off = render(open_flows(conn, board))

      assert off =~ "background:var(--color-neutral-content)"

      {:ok, _} = Flows.enable_flow(spec)
      on = render(open_flows(conn, board))

      assert on =~ "background:var(--color-primary-content)"

      for html <- [off, on] do
        knobs = Regex.scan(~r/width:18px;height:18px;border-radius:50%;background:([^;]+);/, html)
        assert knobs != []

        for [_, fill] <- knobs do
          refute fill == "var(--color-base-100)",
                 "the toggle knob must not be a surface token — it inverts in dark"
        end
      end
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

    test "a flow with nothing before it to pull from shows a warning chip and a disabled toggle",
         %{conn: conn, board: board} do
      backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
      {:ok, backlog} = Boards.update_stage(backlog, %{type: :work})

      {:ok, first} =
        Flows.create_flow(board, %{
          key: "first",
          isolation: :shared_clean,
          stage_id: backlog.id,
          nodes: [],
          edges: [%{from: "start", to: "done"}]
        })

      view = open_flows(conn, board)

      assert has_element?(view, "#flow-#{first.id}-trigger", "missing stage")
      assert has_element?(view, "#flow-#{first.id}-toggle[disabled]")
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
      {:ok, _created} =
        Flows.create_flow(board, %{
          "key" => "smoke-gate",
          "isolation" => "shared_clean",
          "stage_id" => deploy_id(board),
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
      {:ok, _created} =
        Flows.create_flow(board, %{
          "key" => "smoke-gate",
          "isolation" => "shared_clean",
          "stage_id" => deploy_id(board),
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

  # RE394 — every flow-settings action that persists shows the shared client-side pressed face,
  # and its panel/menu is the action group whose other controls go inert.
  describe "pressed faces (RE394)" do
    defp face(view, selector), do: view |> element(selector) |> render() |> LazyHTML.from_fragment()
    defp text_at(doc, sel), do: doc |> LazyHTML.query(sel) |> LazyHTML.text() |> String.trim()

    test "a disabled flow's confirm CTA presses to Turning on…; Cancel stays idle", %{conn: conn, board: board} do
      spec = flow(board, "spec")
      view = open_flows(conn, board)
      view |> element("#flow-#{spec.id}-toggle") |> render_click()

      cta = face(view, "#flow-#{spec.id}-confirm-cta")
      assert text_at(cta, ".pending-idle") =~ ~r/^Turn on/
      assert text_at(cta, ".pending-face") == "Turning on…"
      assert has_element?(view, "#flow-#{spec.id}-confirm .action-group #flow-#{spec.id}-confirm-cta.pending-action")
      refute has_element?(view, "#flow-#{spec.id}-confirm-cancel.pending-action")
    end

    test "an enabled flow's confirm CTA presses to Turning off…", %{conn: conn, board: board} do
      spec = flow(board, "spec")
      {:ok, _} = Flows.enable_flow(spec)
      view = open_flows(conn, board)
      view |> element("#flow-#{spec.id}-toggle") |> render_click()

      cta = face(view, "#flow-#{spec.id}-confirm-cta")
      assert text_at(cta, ".pending-idle") =~ ~r/^Turn off/
      assert text_at(cta, ".pending-face") == "Turning off…"
    end

    test "the reset CTA presses to Resetting…", %{conn: conn, board: board} do
      plan = flow(board, "plan")

      {:ok, plan} =
        Flows.update_flow(plan, %{
          nodes: [%{key: "write_plan", type: :agent, run: "custom run", max_retries: 3}],
          edges: [%{from: "start", to: "write_plan"}, %{from: "write_plan", to: "done", on: :succeeded}]
        })

      view = open_flows(conn, board)
      view |> element("#flow-#{plan.id}-reset") |> render_click()

      assert text_at(face(view, "#flow-#{plan.id}-reset-cta"), ".pending-face") == "Resetting…"
      assert has_element?(view, "#flow-#{plan.id}-reset-confirm .action-group #flow-#{plan.id}-reset-cancel")
      refute has_element?(view, "#flow-#{plan.id}-reset-cancel.pending-action")
    end

    test "the delete CTA presses to Deleting…", %{conn: conn, board: board} do
      spec = flow(board, "spec")
      view = open_flows(conn, board)
      view |> element("#flow-#{spec.id}-delete") |> render_click()

      assert text_at(face(view, "#flow-#{spec.id}-delete-cta"), ".pending-face") == "Deleting…"
      assert has_element?(view, "#flow-#{spec.id}-delete-confirm .action-group #flow-#{spec.id}-delete-cancel")
      refute has_element?(view, "#flow-#{spec.id}-delete-cancel.pending-action")
    end

    test "the new-flow form's Create flow presses to Creating…", %{conn: conn, board: board} do
      view = open_new_flow(conn, board)

      create = face(view, "#new-flow-create")
      assert text_at(create, ".pending-idle") == "Create flow"
      assert text_at(create, ".pending-face") == "Creating…"
      assert has_element?(view, "#new-flow-form.action-group #new-flow-create.pending-action[type=submit]")
      refute has_element?(view, "#new-flow-cancel.pending-action")
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

      assert button =~ "background:var(--color-primary)"
      assert button =~ "color:var(--color-primary-content)"
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

  describe "one Stage select (RE429)" do
    defp option_texts(view, selector) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
    end

    test "30. the new-flow form picks one stage and previews the derived pickup and drop-off",
         %{conn: conn, board: board} do
      view = open_new_flow(conn, board)
      deploy = Enum.find(Boards.list_stages(board), &(&1.name == "Deploy"))

      assert option_texts(view, "#new-flow-stage option") == ["—", "Deploy"]
      assert has_element?(view, "#new-flow-stage[name='flow[stage_id]']")
      refute has_element?(view, "#new-flow-pulls-from")
      refute has_element?(view, "#new-flow-works-in")
      refute has_element?(view, "#new-flow-lands-on")

      view |> form("#new-flow-form", %{"flow" => %{"stage_id" => deploy.id}}) |> render_change()
      assert has_element?(view, "#new-flow-derived", "Review")
      assert has_element?(view, "#new-flow-derived", "Done")

      view
      |> form("#new-flow-form", %{"flow" => %{"key" => "nostage", "stage_id" => ""}})
      |> render_submit()

      assert has_element?(view, "#new-flow-form", "is required")
      assert Flows.get_flow(board, "nostage") == nil

      assert {:error, {:live_redirect, _}} =
               view
               |> form("#new-flow-form", %{"flow" => %{"key" => "ship", "stage_id" => deploy.id}})
               |> render_submit()

      assert %Flow{enabled: false} = ship = Flows.get_flow(board, "ship")
      assert ship.stage_id == deploy.id
    end

    test "31. rows carry no Duplicate item and chip the derived trigger",
         %{conn: conn, board: board} do
      code = flow(board, "code")
      view = open_flows(conn, board)

      refute has_element?(view, "#flow-#{code.id}-duplicate")
      assert has_element?(view, "#flow-#{code.id}-trigger", "Plan:Done")
      assert has_element?(view, "#flow-#{code.id}-trigger", "Code")
      assert has_element?(view, "#flow-#{code.id}-trigger", "Review")
    end
  end

  describe "creating a flow from scratch (RLY-158)" do
    test "clicking the button opens the panel with the key prefilled and isolation defaulted",
         %{conn: conn, board: board} do
      view = open_new_flow(conn, board)

      assert has_element?(view, "#new-flow-form")
      assert has_element?(view, "#new-flow-key[value='new-flow']")
      assert has_element?(view, "#new-flow-stage")
      assert has_element?(view, "#new-flow-isolation option[value='shared_clean'][selected]")
    end

    test "creating a flow persists it disabled and navigates to the editor",
         %{conn: conn, board: board} do
      view = open_new_flow(conn, board)
      deploy = deploy_id(board)

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#new-flow-form", %{
                 "flow" => %{
                   "key" => "deploy-gate",
                   "isolation" => "shared_clean",
                   "stage_id" => to_string(deploy)
                 }
               })
               |> render_submit()

      assert to == "/board/#{board.slug}/flows/deploy-gate"

      created = Flows.get_flow!(board, "deploy-gate")
      refute created.enabled
      assert created.version == 1
      assert created.nodes == []
      assert [%{from: "start", to: "done", on: nil}] = created.edges
      assert created.stage_id == deploy
    end

    test "creating a flow lands on an editor that actually renders (no crash on the empty graph)",
         %{conn: conn, board: board} do
      view = open_new_flow(conn, board)
      deploy = deploy_id(board)

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#new-flow-form", %{
                 "flow" => %{
                   "key" => "deploy-gate",
                   "isolation" => "shared_clean",
                   "stage_id" => to_string(deploy)
                 }
               })
               |> render_submit()

      assert to == "/board/#{board.slug}/flows/deploy-gate"

      # Follow the redirect the shipped test never followed — the editor must mount and render.
      {:ok, editor, _html} = live(conn, to)
      assert has_element?(editor, "#flow-graph")
    end

    test "the created flow's row shows 0 nodes and an off toggle",
         %{conn: conn, board: board} do
      view = open_new_flow(conn, board)
      deploy = deploy_id(board)

      view
      |> form("#new-flow-form", %{
        "flow" => %{
          "key" => "deploy-gate",
          "isolation" => "shared_clean",
          "stage_id" => to_string(deploy)
        }
      })
      |> render_submit()

      created = Flows.get_flow!(board, "deploy-gate")
      view = open_flows(conn, board)

      assert has_element?(view, "#flow-#{created.id}-nodes-count", "0 nodes")
      assert has_element?(view, "#flow-#{created.id}-toggle[aria-pressed='false']")
    end

    test "a blank stage keeps the panel open with an inline error",
         %{conn: conn, board: board} do
      view = open_new_flow(conn, board)

      html =
        view
        |> form("#new-flow-form", %{
          "flow" => %{
            "key" => "deploy-gate",
            "isolation" => "shared_clean",
            "stage_id" => ""
          }
        })
        |> render_submit()

      assert has_element?(view, "#new-flow-form")
      assert html =~ "is required"
      assert Flows.get_flow(board, "deploy-gate") == nil
    end

    test "a duplicate key keeps the panel open and preserves the stage selection",
         %{conn: conn, board: board} do
      view = open_new_flow(conn, board)
      deploy = deploy_id(board)

      html =
        view
        |> form("#new-flow-form", %{
          "flow" => %{
            "key" => "spec",
            "isolation" => "shared_clean",
            "stage_id" => to_string(deploy)
          }
        })
        |> render_submit()

      assert has_element?(view, "#new-flow-form")
      assert html =~ "has already been taken"
      assert has_element?(view, "#new-flow-stage option[value='#{deploy}'][selected]")
    end

    test "a malformed key is rejected inline", %{conn: conn, board: board} do
      view = open_new_flow(conn, board)
      deploy = deploy_id(board)

      html =
        view
        |> form("#new-flow-form", %{
          "flow" => %{
            "key" => "Deploy Gate!",
            "isolation" => "shared_clean",
            "stage_id" => to_string(deploy)
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
          "stage_id" => "1"
        }
      })

      assert render(view) =~ "archived (read-only)"
      assert Flows.get_flow(board, "sneaky") == nil
    end
  end

  describe "delete flow (RLY-221)" do
    test "the Delete item is absent for an enabled flow and present for a disabled one",
         %{conn: conn, board: board} do
      spec = flow(board, "spec")
      view = open_flows(conn, board)

      # seeded flows are disabled → Delete is offered
      assert has_element?(view, "#flow-#{spec.id}-delete", "Delete flow")

      # enable it → Delete disappears
      {:ok, _} = Flows.enable_flow(spec)
      view = open_flows(conn, board)
      refute has_element?(view, "#flow-#{spec.id}-delete")
    end

    test "clicking Delete opens the confirm panel; confirming removes the row for good",
         %{conn: conn, board: board} do
      spec = flow(board, "spec")
      view = open_flows(conn, board)

      view |> element("#flow-#{spec.id}-delete") |> render_click()
      assert has_element?(view, "#flow-#{spec.id}-delete-confirm", "Delete the Spec flow?")

      view |> element("#flow-#{spec.id}-delete-cta") |> render_click()

      refute has_element?(view, "#flow-row-#{spec.id}")
      assert Flows.get_flow(board, "spec") == nil

      # and it does not return on reload
      view = open_flows(conn, board)
      refute has_element?(view, "#flow-row-#{spec.id}")
    end

    test "cancel closes the confirm panel without deleting", %{conn: conn, board: board} do
      spec = flow(board, "spec")
      view = open_flows(conn, board)

      view |> element("#flow-#{spec.id}-delete") |> render_click()
      view |> element("#flow-#{spec.id}-delete-cancel") |> render_click()

      refute has_element?(view, "#flow-#{spec.id}-delete-confirm")
      assert Flows.get_flow(board, "spec")
    end

    test "the confirm panel warns when cards are mid-run, then delete nil-s their flow_id",
         %{conn: conn, board: board} do
      spec = flow(board, "spec")
      run = insert(:run, flow_id: spec.id, status: :running)
      view = open_flows(conn, board)

      view |> element("#flow-#{spec.id}-delete") |> render_click()
      assert has_element?(view, "#flow-#{spec.id}-delete-midrun", "mid-run on this flow")
      assert has_element?(view, "#flow-#{spec.id}-delete-midrun", "no_flow")

      view |> element("#flow-#{spec.id}-delete-cta") |> render_click()

      assert Flows.get_flow(board, "spec") == nil
      assert Repo.reload(run).flow_id == nil
    end

    test "an archived board rejects delete as read-only", %{conn: conn, board: board} do
      spec = flow(board, "spec")
      {:ok, _} = Boards.archive_board(board)
      view = open_flows(conn, board)

      render_click(view, "flow_delete", %{"flow-id" => to_string(spec.id)})
      assert render(view) =~ "archived (read-only)"

      render_click(view, "flow_confirm_delete", %{"flow-id" => to_string(spec.id)})
      assert render(view) =~ "archived (read-only)"
      assert Flows.get_flow(board, "spec")
    end
  end
end
