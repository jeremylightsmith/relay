defmodule HamacaWeb.BoardLiveStoryMapBulkMoveTest do
  @moduledoc """
  RE502 — moving a story-map selection from the bulk bar: the Stage menu (nested picker, silent
  unless runs would strand), the Release menu (with "(No release)"), the Step menu (act
  headers), the menus' filter, and the batched RLY-217 live-run confirm — cancel and move all,
  move the others only, or keep.
  """
  use HamacaWeb.ConnCase, async: true

  import Ecto.Query
  import Hamaca.Factory
  import Phoenix.LiveViewTest

  alias Hamaca.Boards
  alias Hamaca.Cards
  alias Hamaca.Repo
  alias Hamaca.Runs
  alias Hamaca.Runs.FakeDispatcher
  alias Hamaca.StoryMap
  alias Schemas.Activity
  alias Schemas.Card

  setup :register_and_log_in_user

  # The shared fixture for every scenario: Backlog, Plan (no flow), Design (flow) with its
  # Review sub-lane, Code (flow) and Done; one activity with steps S1 and S2; releases R1, R2.
  setup %{user: user} do
    FakeDispatcher.register(self())
    start_engine!()

    board = insert(:board, owner: user)
    insert(:membership, board: board, user: user)

    backlog = insert(:stage, board: board, name: "Backlog", type: :queue, position: 1)
    plan = insert(:stage, board: board, name: "Plan", type: :queue, position: 2)
    design = insert(:stage, board: board, name: "Design", type: :work, category: :in_progress, position: 3)

    review =
      insert(:stage, board: board, parent_id: design.id, name: "Design:Review", type: :review, position: 4)

    code = insert(:stage, board: board, name: "Code", type: :work, category: :in_progress, position: 5)
    done = insert(:stage, board: board, name: "Done", type: :done, category: :complete, position: 6)

    insert(:flow, board: board, key: "design", stage_id: design.id)
    code_flow = insert(:flow, board: board, key: "code", stage_id: code.id)

    activity = insert(:story_activity, board: board, name: "Plan the backlog", position: 1)
    s1 = insert(:story_step, story_activity: activity, name: "Sign in", position: 1)
    s2 = insert(:story_step, story_activity: activity, name: "Organize", position: 2)
    r1 = insert(:release, board: board, name: "MVP", position: 1)
    r2 = insert(:release, board: board, name: "Fast follow", position: 2)

    # Done is a complete column; the map hides those by default (RE276), which would prune the
    # moved cards out of the selection the scenarios check is kept.
    {:ok, _view} = StoryMap.put_view(board, "hide_complete", false)

    %{
      board: board,
      backlog: backlog,
      plan: plan,
      design: design,
      review: review,
      code: code,
      done: done,
      code_flow: code_flow,
      activity: activity,
      s1: s1,
      s2: s2,
      r1: r1,
      r2: r2
    }
  end

  defp placed(ctx, stage, title, step, release, position) do
    insert(:card,
      stage: stage,
      title: title,
      story_activity_id: ctx.activity.id,
      story_step_id: step.id,
      release_id: release.id,
      story_map_position: position
    )
  end

  defp park_run(ctx, card) do
    insert(:run,
      card: card,
      flow_id: ctx.code_flow.id,
      flow_key: ctx.code_flow.key,
      status: :parked,
      current_node: "implement"
    )
  end

  defp map_path(board), do: ~p"/board/#{board.slug}/story-map"
  defp ref(board, card), do: Cards.ref(board, card)

  defp open_map(conn, ctx, cards) do
    {:ok, view, _html} = live(conn, map_path(ctx.board))
    Enum.each(cards, &toggle(view, ctx.board, &1))
    view
  end

  defp toggle(view, board, card), do: render_hook(view, "toggle_card_selection", %{"ref" => ref(board, card)})
  defp open_menu(view, menu), do: render_hook(view, "open_bulk_menu", %{"menu" => menu})
  defp click(view, selector), do: view |> element(selector) |> render_click()

  defp text(view, selector), do: view |> element(selector) |> render() |> squish()

  defp squish(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  defp bar_count(view), do: text(view, "#story-map-bulk-bar .badge")

  defp reload(card), do: Repo.get!(Card, card.id)

  defp has_flash?(view), do: has_element?(view, "#flash-info") or has_element?(view, "#flash-error")

  defp row_ids(view, menu_id) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("##{menu_id} [id^='#{menu_id}-']")
    |> LazyHTML.attribute("id")
    |> Enum.reject(&String.ends_with?(&1, ["-filter", "-filter-form"]))
  end

  describe "the Stage menu (scenario 3)" do
    test "renders the nested picker with the selection's marks and no counts", %{conn: conn} = ctx do
      a = placed(ctx, ctx.backlog, "A", ctx.s1, ctx.r1, 0)
      b = placed(ctx, ctx.backlog, "B", ctx.s1, ctx.r1, 1)
      c = placed(ctx, ctx.code, "C", ctx.s1, ctx.r1, 2)
      view = open_map(conn, ctx, [a, b, c])

      open_menu(view, "stage")

      assert text(view, "#bulk-stage-menu") =~ "MOVE 3 CARDS TO STAGE"
      assert has_element?(view, "#bulk-stage-menu-#{ctx.backlog.id} .h-\\[2px\\]")
      assert has_element?(view, "#bulk-stage-menu-#{ctx.code.id} .h-\\[2px\\]")
      refute has_element?(view, "#bulk-stage-menu .hero-check")
      assert text(view, "#bulk-stage-menu-#{ctx.review.id}") =~ ~r/^─\s*Review$/
      assert has_element?(view, "#bulk-stage-menu-#{ctx.review.id} .w-px.bg-base-300")
      assert has_element?(view, "#bulk-stage-menu-#{ctx.design.id} .bg-secondary")
      assert has_element?(view, "#bulk-stage-menu-#{ctx.backlog.id} .bg-primary\\/45")
      assert has_element?(view, "#bulk-stage-menu.max-h-\\[60vh\\]")
      assert has_element?(view, "#story-map-bulk-stage.btn-primary")
      refute text(view, "#bulk-stage-menu") =~ ~r/\d+ of \d+/
    end
  end

  describe "a direct Stage move (scenarios 4, 5)" do
    test "moves every card silently, in map order, keeping the selection", %{conn: conn, user: user} = ctx do
      existing = insert(:card, stage: ctx.done, title: "Already done")
      a = placed(ctx, ctx.backlog, "A", ctx.s1, ctx.r1, 0)
      b = placed(ctx, ctx.plan, "B", ctx.s1, ctx.r1, 1)
      c = placed(ctx, ctx.code, "C", ctx.s1, ctx.r1, 2)
      view = open_map(conn, ctx, [c, a, b])

      open_menu(view, "stage")
      click(view, "#bulk-stage-menu-#{ctx.done.id}")

      done_ids =
        Repo.all(from c in Card, where: c.stage_id == ^ctx.done.id, order_by: c.position, select: c.id)

      assert done_ids == [existing.id, a.id, b.id, c.id]
      refute has_element?(view, "#bulk-move-modal")
      refute has_flash?(view)

      for card <- [a, b, c] do
        assert [%Activity{actor_type: :user, user_id: user_id}] =
                 Repo.all(from e in Activity, where: e.card_id == ^card.id and e.type == :moved)

        assert user_id == user.id
      end

      refute has_element?(view, "#bulk-stage-menu")
      assert bar_count(view) == "3 selected"
    end

    test "the stage every card is already on is inert, and pushing it anyway is a no-op", %{conn: conn} = ctx do
      a = placed(ctx, ctx.backlog, "A", ctx.s1, ctx.r1, 0)
      b = placed(ctx, ctx.backlog, "B", ctx.s1, ctx.r1, 1)
      view = open_map(conn, ctx, [a, b])

      open_menu(view, "stage")

      assert has_element?(view, "div#bulk-stage-menu-#{ctx.backlog.id} .hero-check")
      refute has_element?(view, "button#bulk-stage-menu-#{ctx.backlog.id}")

      render_click(view, "bulk_move_stage", %{"stage_id" => to_string(ctx.backlog.id)})

      assert reload(a).position == a.position
      assert reload(b).position == b.position
      refute has_flash?(view)
    end
  end

  describe "the batched live-run confirm (scenarios 6-10)" do
    test "N excludes the cards already in the target, so a lone runner has no others button",
         %{conn: conn} = ctx do
      a = placed(ctx, ctx.backlog, "A", ctx.s1, ctx.r1, 0)
      b = placed(ctx, ctx.backlog, "B", ctx.s1, ctx.r1, 1)
      c = placed(ctx, ctx.code, "C", ctx.s1, ctx.r1, 2)
      park_run(ctx, c)
      view = open_map(conn, ctx, [a, b, c])

      open_menu(view, "stage")
      click(view, "#bulk-stage-menu-#{ctx.backlog.id}")

      modal = text(view, "#bulk-move-modal")
      assert modal =~ "1 of 1 card has a live run"
      assert modal =~ ref(ctx.board, c)
      assert modal =~ "parked"
      assert modal =~ "implement"
      assert modal =~ "code flow"
      refute has_element?(view, "#bulk-move-others")
      assert reload(c).stage_id == ctx.code.id
    end

    test "opens with the counts and moves nothing; Keep closes it", %{conn: conn} = ctx do
      {view, a, b, c, _run} = open_confirm(conn, ctx)

      assert text(view, "#bulk-move-modal") =~ "1 of 3 cards has a live run"
      assert text(view, "#bulk-move-cancel-runs .pending-idle") == "Cancel 1 run & move all 3"
      assert text(view, "#bulk-move-others .pending-idle") == "Move the other 2 only"
      assert text(view, "#bulk-move-keep") == "Keep all here"
      assert has_element?(view, "#bulk-move-modal.modal.modal-open .modal-box.max-w-md .modal-action.action-group")
      assert has_element?(view, "#bulk-move-cancel-runs.btn.btn-error")
      assert has_element?(view, "#bulk-move-running li", ref(ctx.board, c))
      assert_stages([a, b, c], [ctx.plan, ctx.plan, ctx.code])

      click(view, "#bulk-move-keep")

      refute has_element?(view, "#bulk-move-modal")
      assert_stages([a, b, c], [ctx.plan, ctx.plan, ctx.code])
    end

    test "Move the others moves only the idle cards; Cancel & move all then moves the runner",
         %{conn: conn, user: user} = ctx do
      {view, a, b, c, run} = open_confirm(conn, ctx)

      click(view, "#bulk-move-others")

      refute has_element?(view, "#bulk-move-modal")
      assert_stages([a, b, c], [ctx.backlog, ctx.backlog, ctx.code])
      assert Repo.get!(Schemas.Run, run.id).status == :parked
      assert bar_count(view) == "3 selected"

      toggle(view, ctx.board, a)
      toggle(view, ctx.board, b)
      open_menu(view, "stage")
      click(view, "#bulk-stage-menu-#{ctx.backlog.id}")

      assert text(view, "#bulk-move-modal") =~ "1 of 1 card has a live run"
      assert text(view, "#bulk-move-cancel-runs .pending-idle") == "Cancel 1 run & move all 1"

      click(view, "#bulk-move-cancel-runs")

      assert reload(c).stage_id == ctx.backlog.id
      assert Repo.get!(Schemas.Run, run.id).status == :cancelled

      entry =
        c
        |> reload()
        |> Hamaca.Activity.list_timeline()
        |> Enum.find(&match?(%Activity{type: :action, text: "run cancelled"}, &1))

      assert entry.actor_type == :user
      assert entry.user_id == user.id
    end

    test "the backdrop and Esc both mean Keep", %{conn: conn} = ctx do
      {view, a, b, c, _run} = open_confirm(conn, ctx)

      click(view, ~s(label.modal-backdrop[phx-click="bulk_move_keep"]))

      refute has_element?(view, "#bulk-move-modal")
      assert_stages([a, b, c], [ctx.plan, ctx.plan, ctx.code])

      open_menu(view, "stage")
      click(view, "#bulk-stage-menu-#{ctx.backlog.id}")
      assert has_element?(view, "#bulk-move-modal")

      render_hook(view, "story_map_selection_escape", %{})

      refute has_element?(view, "#bulk-move-modal")
      assert bar_count(view) == "3 selected"
      assert_stages([a, b, c], [ctx.plan, ctx.plan, ctx.code])
    end

    test "re-checks at apply time and flashes the skipped count", %{conn: conn} = ctx do
      {view, a, b, c, run} = open_confirm(conn, ctx)

      {:ok, _cancelled} = Runs.cancel_run(run)
      {:ok, _archived} = Cards.archive_card(reload(b))

      click(view, "#bulk-move-cancel-runs")

      assert reload(a).stage_id == ctx.backlog.id
      assert reload(c).stage_id == ctx.backlog.id
      assert reload(b).stage_id == ctx.plan.id
      assert text(view, "#flash-info") =~ "Moved 2 · 1 skipped"
    end
  end

  # Scenario 7's state: A and B in Plan, C in Code with a parked Code-flow run, all selected,
  # and the Backlog row clicked.
  defp open_confirm(conn, ctx) do
    a = placed(ctx, ctx.plan, "A", ctx.s1, ctx.r1, 0)
    b = placed(ctx, ctx.plan, "B", ctx.s1, ctx.r1, 1)
    c = placed(ctx, ctx.code, "C", ctx.s1, ctx.r1, 2)
    run = park_run(ctx, c)
    view = open_map(conn, ctx, [a, b, c])

    open_menu(view, "stage")
    click(view, "#bulk-stage-menu-#{ctx.backlog.id}")

    {view, a, b, c, run}
  end

  defp assert_stages(cards, stages) do
    assert Enum.map(cards, &reload(&1).stage_id) == Enum.map(stages, & &1.id)
  end

  describe "the Release and Step menus (scenarios 11-13)" do
    test "Release moves keep the step and stage; Step moves keep the release", %{conn: conn} = ctx do
      a = placed(ctx, ctx.backlog, "A", ctx.s1, ctx.r1, 0)
      b = placed(ctx, ctx.plan, "B", ctx.s2, ctx.r1, 0)
      view = open_map(conn, ctx, [a, b])

      open_menu(view, "release")

      assert text(view, "#bulk-release-menu") =~ "MOVE 2 CARDS TO RELEASE"
      assert has_element?(view, "div#bulk-release-menu-#{ctx.r1.id} .hero-check")
      refute has_element?(view, "button#bulk-release-menu-#{ctx.r1.id}")
      assert List.last(row_ids(view, "bulk-release-menu")) == "bulk-release-menu-none"
      assert text(view, "#bulk-release-menu-none") == "(No release)"

      click(view, "#bulk-release-menu-#{ctx.r2.id}")

      assert {reload(a).story_step_id, reload(a).release_id} == {ctx.s1.id, ctx.r2.id}
      assert {reload(b).story_step_id, reload(b).release_id} == {ctx.s2.id, ctx.r2.id}
      assert reload(a).stage_id == ctx.backlog.id
      assert reload(b).stage_id == ctx.plan.id

      # Scenario 12 — the Step menu, from the state above.
      open_menu(view, "step")

      header =
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#bulk-step-menu div.uppercase")

      assert header |> LazyHTML.text() |> String.trim() == ctx.activity.name
      assert Enum.count(header) == 1
      assert LazyHTML.attribute(header, "phx-click") == []
      assert has_element?(view, "#bulk-step-menu-#{ctx.s1.id} .h-\\[2px\\]")
      assert has_element?(view, "#bulk-step-menu-#{ctx.s2.id} .h-\\[2px\\]")

      click(view, "#bulk-step-menu-#{ctx.s2.id}")

      assert {reload(a).story_step_id, reload(a).release_id} == {ctx.s2.id, ctx.r2.id}
      assert {reload(b).story_step_id, reload(b).release_id} == {ctx.s2.id, ctx.r2.id}
    end

    test "(No release) clears the release and keeps the step", %{conn: conn} = ctx do
      a = placed(ctx, ctx.backlog, "A", ctx.s1, ctx.r1, 0)
      view = open_map(conn, ctx, [a])

      open_menu(view, "release")
      assert text(view, "#bulk-release-menu") =~ "MOVE 1 CARD TO RELEASE"
      click(view, "#bulk-release-menu-none")

      assert %Card{release_id: nil, story_step_id: step_id} = reload(a)
      assert step_id == ctx.s1.id
    end
  end

  describe "the menus' filter (scenario 14)" do
    test "narrows to the flattened sub-lane and resets when the menu changes", %{conn: conn} = ctx do
      a = placed(ctx, ctx.backlog, "A", ctx.s1, ctx.r1, 0)
      view = open_map(conn, ctx, [a])

      open_menu(view, "stage")
      view |> element("#bulk-stage-menu-filter-form") |> render_change(%{"q" => "rev"})

      assert row_ids(view, "bulk-stage-menu") == ["bulk-stage-menu-#{ctx.review.id}"]
      assert text(view, "#bulk-stage-menu-#{ctx.review.id}") == "Design · Review"

      open_menu(view, "release")

      assert view |> element("#bulk-release-menu-filter") |> render() =~ ~s(value="")
    end
  end

  describe "guards (scenarios 15, 16)" do
    test "a read-only board refuses every bulk move with the read-only flash", %{conn: conn} = ctx do
      a = placed(ctx, ctx.backlog, "A", ctx.s1, ctx.r1, 0)
      {:ok, _archived} = Boards.archive_board(ctx.board)
      {:ok, view, _html} = live(conn, map_path(ctx.board))

      render_hook(view, "bulk_move_stage", %{"stage_id" => to_string(ctx.done.id)})
      assert text(view, "#flash-error") =~ "read-only"

      render_hook(view, "bulk_move_release", %{"release_id" => to_string(ctx.r2.id)})
      render_hook(view, "bulk_move_confirm", %{"mode" => "all"})
      render_hook(view, "bulk_move_step", %{"step_id" => to_string(ctx.s2.id)})
      render_hook(view, "bulk_move_keep", %{})

      assert %Card{stage_id: stage_id, release_id: release_id, story_step_id: step_id} = reload(a)
      assert {stage_id, release_id, step_id} == {ctx.backlog.id, ctx.r1.id, ctx.s1.id}
      assert text(view, "#flash-error") =~ "read-only"
    end

    test "an unknown stage, a foreign release and a bogus mode are silent no-ops", %{conn: conn} = ctx do
      a = placed(ctx, ctx.backlog, "A", ctx.s1, ctx.r1, 0)
      foreign = insert(:release, board: insert(:board), name: "Elsewhere")
      view = open_map(conn, ctx, [a])

      render_hook(view, "bulk_move_stage", %{"stage_id" => "999999"})
      render_hook(view, "bulk_move_release", %{"release_id" => to_string(foreign.id)})
      render_hook(view, "bulk_move_step", %{"step_id" => "999999"})
      render_hook(view, "bulk_move_confirm", %{"mode" => "bogus"})
      render_hook(view, "bulk_move_confirm", %{"mode" => "all"})

      assert %Card{stage_id: stage_id, release_id: release_id, story_step_id: step_id} = reload(a)
      assert {stage_id, release_id, step_id} == {ctx.backlog.id, ctx.r1.id, ctx.s1.id}
      refute has_element?(view, "#bulk-move-modal")
      refute has_flash?(view)
      assert bar_count(view) == "1 selected"
    end
  end
end
