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

    test "the header carries no version language and no + New flow button",
         %{conn: conn, board: board} do
      view = open_flows(conn, board)

      assert has_element?(view, "#flows-pane", "A flow is the automation attached to a stage transition")
      refute render(view) =~ "versioned"
      refute render(view) =~ "New flow"
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
      assert has_element?(view, "#flow-#{code.id}-nodes-count", "14 nodes")

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

    test "the footer cutover note and the engine note are present", %{conn: conn, board: board} do
      view = open_flows(conn, board)

      assert has_element?(view, "#flows-footer-note", "Disabling a flow is a cutover")
      assert has_element?(view, "#flows-engine-note", "RLY-133")
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
    test "toggle opens the enable confirm with the double-dispatch ritual; cancel persists nothing",
         %{conn: conn, board: board} do
      spec = flow(board, "spec")
      view = open_flows(conn, board)

      view |> element("#flow-#{spec.id}-toggle") |> render_click()

      assert has_element?(view, "#flow-#{spec.id}-confirm", "Turn on the Spec flow?")
      assert has_element?(view, "#flow-#{spec.id}-confirm", "handed to the AI automatically")
      assert has_element?(view, "#flow-#{spec.id}-confirm", "bin/relay watch")
      assert has_element?(view, "#flow-#{spec.id}-confirm", "relay_config.json")
      assert has_element?(view, "#flow-#{spec.id}-confirm", "double dispatch")
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
      assert has_element?(view, "#flow-#{spec.id}-confirm", "re-add this stage's entry")

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
end
