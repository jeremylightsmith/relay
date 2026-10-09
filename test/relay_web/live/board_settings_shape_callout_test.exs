defmodule RelayWeb.BoardSettingsShapeCalloutTest do
  @moduledoc """
  RE432 — Board Settings → Stages makes a flow paused by a broken board shape loud and
  one-click fixable: the paused row is amber-bordered with a PAUSED badge, an amber chip and a
  dashed offending neighbour; a Shape callout renders the `Relay.Flows.Shape` problem with FIX
  buttons that apply at once; and an "N flows are paused" summary heads the pane. Every domain
  sentence is compared against the domain's own problem, never re-typed.
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

  defp query(view, selector), do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp attr(view, selector, name), do: view |> query(selector) |> LazyHTML.attribute(name) |> List.first()

  defp text(view, selector), do: view |> query(selector) |> LazyHTML.text() |> squish()

  defp squish(string), do: string |> String.split() |> Enum.join(" ")

  defp problem_for(board, key), do: Enum.find(Flows.shape_problems(board), &(&1.flow_key == key))

  defp enable!(board, key) do
    {:ok, flow} = Flows.enable_flow(Flows.get_flow!(board, key))
    flow
  end

  # Seeded board + an enabled deploy flow: Deploy pulls from Review → `:upstream_review`.
  defp add_deploy_flow(board) do
    deploy = stage_named(board, "Deploy")
    insert_flow_working_in(deploy, key: "deploy", enabled: true)
    deploy
  end

  # Enabled `plan` with Spec · Done off: Plan pulls from Spec · Review → `:upstream_review`.
  defp break_plan(board) do
    enable!(board, "plan")
    {:ok, _} = Boards.disable_lane(stage_named(board, "Spec"), :done)
    stage_named(board, "Plan")
  end

  # Review deleted, deploy flow on: Deploy pulls from Code's working stage → `:upstream_working`.
  defp break_deploy_after_code(board) do
    {:ok, _} = Boards.delete_stage(stage_named(board, "Review"))
    add_deploy_flow(board)
  end

  defp assert_callout(view, board, stage, key, kind) do
    problem = problem_for(board, key)
    assert problem.kind == kind
    assert problem.stage_id == stage.id

    callout = "#stage-#{stage.id}-row #stage-#{stage.id}-shape-callout"
    assert attr(view, callout, "data-kind") == to_string(problem.kind)
    assert text(view, "#stage-#{stage.id}-shape-callout-what") == squish(Relay.Markdown.to_plain(problem.what))
    problem
  end

  describe "the paused row" do
    test "12. a paused flow's row is loud and carries its callout; healthy rows stay plain",
         %{conn: conn, board: board} do
      deploy = add_deploy_flow(board)
      code = stage_named(board, "Code")
      view = open_stages(conn, board)

      assert attr(view, "#stage-#{deploy.id}-row", "data-paused") == "true"

      assert attr(view, "#stage-#{deploy.id}-row", "style") =~
               "border:2px solid color-mix(in oklab, var(--color-warning) 70%, var(--color-base-100))"

      assert text(view, "#stage-#{deploy.id}-paused-badge") == "PAUSED"
      assert attr(view, "#stage-#{deploy.id}-ai-flow", "data-flow-paused") == "true"
      assert attr(view, "#stage-#{deploy.id}-neighbours-pulls-from", "style") =~ "1.5px dashed"

      problem = problem_for(board, "deploy")

      assert text(view, "#stage-#{deploy.id}-shape-callout-what") ==
               squish(Relay.Markdown.to_plain(problem.what))

      assert attr(view, "#stage-#{code.id}-row", "data-paused") == "false"
      refute has_element?(view, "#stage-#{code.id}-shape-callout")
      refute has_element?(view, "#stage-#{code.id}-paused-badge")
    end
  end

  describe "13. every kind lands on the right row" do
    test ":upstream_review — Plan pulls from Spec · Review", %{conn: conn, board: board} do
      plan = break_plan(board)
      view = open_stages(conn, board)

      assert_callout(view, board, plan, "plan", :upstream_review)
    end

    test ":upstream_working — Deploy pulls from Code", %{conn: conn, board: board} do
      deploy = break_deploy_after_code(board)
      view = open_stages(conn, board)

      problem = assert_callout(view, board, deploy, "deploy", :upstream_working)
      assert text(view, "#stage-#{deploy.id}-shape-callout-fix-0") == "Turn on Code · Done"
      assert text(view, "#stage-#{deploy.id}-shape-callout-fix-0") == hd(problem.fixes).label
    end

    test ":no_upstream — Spec moved to the front", %{conn: conn, board: board} do
      enable!(board, "spec")
      spec = stage_named(board, "Spec")
      {:ok, _} = Boards.place_stage(spec, before: stage_named(board, "Backlog"))
      view = open_stages(conn, board)

      assert_callout(view, board, spec, "spec", :no_upstream)
      assert text(view, "#stage-#{spec.id}-neighbours-pulls-from") == "none"
      assert attr(view, "#stage-#{spec.id}-neighbours-pulls-from", "style") =~ "1.5px dashed"
      assert text(view, "#stage-#{spec.id}-shape-callout-order-missing-before") == "?"
    end

    test ":no_downstream — Code moved to the end", %{conn: conn, board: board} do
      enable!(board, "code")
      code = stage_named(board, "Code")
      {:ok, _} = Boards.place_stage(code, after: stage_named(board, "Done"))
      view = open_stages(conn, board)

      assert_callout(view, board, code, "code", :no_downstream)
      assert attr(view, "#stage-#{code.id}-neighbours-lands-on", "style") =~ "1.5px dashed"
      assert text(view, "#stage-#{code.id}-shape-callout-fix-0") == "Turn on Code · Done"
      assert text(view, "#stage-#{code.id}-shape-callout-fix-1") == "Add a stage after Code"
    end
  end

  describe "one-click fixes" do
    test "14. clicking the first fix turns on Code · Done and the row goes quiet", %{conn: conn, board: board} do
      deploy = break_deploy_after_code(board)
      view = open_stages(conn, board)
      assert has_element?(view, "#stages-paused-summary")

      fix = element(view, "#stage-#{deploy.id}-shape-callout-fix-0")
      refute attr(view, "#stage-#{deploy.id}-shape-callout-fix-0", "data-confirm")
      render_click(fix)

      assert Enum.any?(Boards.sublanes(stage_named(board, "Code")), &(&1.type == :done))
      refute has_element?(view, "#stage-#{deploy.id}-shape-callout")
      refute has_element?(view, "#stage-#{deploy.id}-paused-badge")
      refute has_element?(view, "#stages-paused-summary")
    end

    test "15. inserting a queue stage puts \"Ready for Plan\" right before Plan", %{conn: conn, board: board} do
      plan = break_plan(board)
      view = open_stages(conn, board)

      view |> element("#stage-#{plan.id}-shape-callout-fix-1") |> render_click()

      mains = board |> Boards.list_stages() |> Enum.filter(&is_nil(&1.parent_id))
      index = Enum.find_index(mains, &(&1.id == plan.id))
      ready = Enum.at(mains, index - 1)
      assert ready.name == "Ready for Plan"
      assert ready.type == :queue
      refute has_element?(view, "#stage-#{plan.id}-shape-callout")
    end
  end

  describe "the paused summary" do
    test "16. counts paused flows and links to the first in board order", %{conn: conn, board: board} do
      deploy = add_deploy_flow(board)
      plan = break_plan(board)
      view = open_stages(conn, board)

      assert text(view, "#stages-paused-summary-link") =~ ~r/^2 flows are paused because of how the board is laid out\./
      assert text(view, "#stages-paused-summary") =~ "2 flows are paused"
      assert attr(view, "#stages-paused-summary-link", "href") == "#stage-#{plan.id}-row"

      view |> element("#stage-#{plan.id}-shape-callout-fix-0") |> render_click()
      assert text(view, "#stages-paused-summary-link") =~ ~r/^1 flow is paused because/
      assert attr(view, "#stages-paused-summary-link", "href") == "#stage-#{deploy.id}-row"

      view |> element("#stage-#{deploy.id}-shape-callout-fix-0") |> render_click()
      refute has_element?(view, "#stages-paused-summary")
    end

    test "17. a disabled flow's problem shows the quiet callout but nothing is paused",
         %{conn: conn, board: board} do
      deploy = add_deploy_flow(board)
      {:ok, _} = Flows.disable_flow(Flows.get_flow!(board, "deploy"))
      view = open_stages(conn, board)

      assert attr(view, "#stage-#{deploy.id}-shape-callout", "data-paused") == "false"
      refute has_element?(view, "#stage-#{deploy.id}-paused-badge")
      assert attr(view, "#stage-#{deploy.id}-row", "data-paused") == "false"
      refute has_element?(view, "#stages-paused-summary")
    end
  end

  describe "liveness and staleness" do
    test "18. a fix made in another session clears the callout live", %{conn: conn, board: board} do
      deploy = add_deploy_flow(board)
      view = open_stages(conn, board)
      assert has_element?(view, "#stage-#{deploy.id}-shape-callout")

      {:ok, _} = Boards.enable_lane(stage_named(board, "Review"), :done)

      refute has_element?(view, "#stage-#{deploy.id}-shape-callout")
    end

    test "19. a stale fix click re-reads the problem and applies nothing", %{conn: conn, board: board} do
      deploy = add_deploy_flow(board)
      view = open_stages(conn, board)
      {:ok, _} = Boards.enable_lane(stage_named(board, "Review"), :done)

      render_click(view, "apply_shape_fix", %{"flow-key" => "deploy", "index" => "1", "action" => "insert_queue_stage"})

      refute Enum.any?(Boards.list_stages(board), &(&1.name == "Ready for Deploy"))
      refute has_element?(view, "#stage-#{deploy.id}-shape-callout")
    end
  end

  describe "an archived board" do
    test "20. shows the callout without FIX buttons and refuses the event", %{conn: conn, board: board} do
      deploy = add_deploy_flow(board)
      {:ok, _} = Boards.archive_board(board)
      view = open_stages(conn, board)
      before = Repo.aggregate(Schemas.Stage, :count)

      assert has_element?(view, "#stage-#{deploy.id}-shape-callout")
      refute has_element?(view, ~s([id^="stage-#{deploy.id}-shape-callout-fix-"]))

      html =
        render_click(view, "apply_shape_fix", %{"flow-key" => "deploy", "index" => "0", "action" => "enable_lane"})

      assert html =~ "This board is archived (read-only)."
      assert Repo.aggregate(Schemas.Stage, :count) == before
      assert has_element?(view, "#stage-#{deploy.id}-shape-callout")
    end
  end
end
