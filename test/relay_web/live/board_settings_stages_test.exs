defmodule RelayWeb.BoardSettingsStagesTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Repo

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  defp stage_named(board, name), do: Enum.find(board.stages, &(&1.name == name))

  describe "two-pane shell" do
    test "renders the rail with Stages active and stage cards grouped by category",
         %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      assert has_element?(view, "#settings-rail")
      assert has_element?(view, "#settings-nav-stages", "Stages")
      assert has_element?(view, "#settings-nav-keys", "API keys")
      assert has_element?(view, "#stages-pane h1", "Stages")
      refute has_element?(view, "#api-key-pane")

      backlog = stage_named(board, "Backlog")
      code = stage_named(board, "Code")
      done = stage_named(board, "Done")
      assert has_element?(view, "#settings-group-unstarted #stage-#{backlog.id}-row")
      assert has_element?(view, "#settings-group-in_progress #stage-#{code.id}-row")
      assert has_element?(view, "#settings-group-complete #stage-#{done.id}-row")
      assert has_element?(view, "#add-stage-unstarted")
      assert has_element?(view, "#add-stage-in_progress")
      assert has_element?(view, "#add-stage-complete")
      assert has_element?(view, "#stage-#{code.id}-name-display", "Code")
      assert has_element?(view, "#stage-#{code.id}-description-display")
      assert has_element?(view, "#stage-#{code.id}-row .stage-type-icon[data-type='work']")
    end

    test "the API-key pane renders under the keys nav with its ids intact", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      view |> element("#settings-nav-keys") |> render_click()

      assert has_element?(view, "#api-key-pane")
      assert has_element?(view, "#generate-key")
      refute has_element?(view, "#stages-pane")

      view |> element("#settings-nav-stages") |> render_click()
      assert has_element?(view, "#stages-pane")
      refute has_element?(view, "#api-key-pane")
    end

    test "the stages pane always shows all four category groups with add buttons", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      for category <- ["unstarted", "planning", "in_progress", "complete"] do
        assert has_element?(view, "#settings-group-#{category}")
        assert has_element?(view, "#add-stage-#{category}")
      end

      assert has_element?(view, "#settings-group-planning", "PLANNING")
      assert has_element?(view, "#add-stage-planning", "+ Add stage to PLANNING")

      [style] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#settings-group-planning .category-dot")
        |> LazyHTML.attribute("style")

      assert style =~ "--color-secondary"
    end
  end

  describe "editing stages" do
    test "the name and description render as click-to-edit read displays", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      assert has_element?(view, "#stage-#{code.id}-name-display", "Code")
      assert has_element?(view, "#stage-#{code.id}-description-display")
      refute has_element?(view, "#stage-#{code.id}-name-form")
    end

    test "renaming a stage persists on explicit save and shows on the board", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      view |> element("#stage-#{code.id}-name-display") |> render_click()

      view
      |> form("#stage-#{code.id}-name-form", stage: %{name: "Build"})
      |> render_submit()

      refute has_element?(view, "#stage-#{code.id}-name-form")
      assert has_element?(view, "#stage-#{code.id}-name-display", "Build")
      assert Boards.get_stage(board, code.id).name == "Build"

      {:ok, board_view, _html} = live(conn, ~p"/board/#{board.slug}")
      assert has_element?(board_view, "#stage-strip-#{code.id} h3", "Build")
    end

    test "a blank rename is rejected inline and keeps the old name", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      view |> element("#stage-#{code.id}-name-display") |> render_click()

      html =
        view
        |> form("#stage-#{code.id}-name-form", stage: %{name: ""})
        |> render_submit()

      assert html =~ "blank"
      assert Boards.get_stage(board, code.id).name == "Code"
    end

    test "editing the description persists on explicit save", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      view |> element("#stage-#{code.id}-description-display") |> render_click()

      view
      |> form("#stage-#{code.id}-description-form", stage: %{description: "Agents write the code"})
      |> render_submit()

      assert Boards.get_stage(board, code.id).description == "Agents write the code"
    end

    test "cancel discards the edit", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      view |> element("#stage-#{code.id}-name-display") |> render_click()
      view |> element("#stage-#{code.id}-name-cancel") |> render_click()

      refute has_element?(view, "#stage-#{code.id}-name-form")
      assert has_element?(view, "#stage-#{code.id}-name-display", "Code")
    end

    test "the arrows reorder stages and crossing a band adopts the category",
         %{conn: conn, board: board} do
      next_up = stage_named(board, "Next up")
      spec = stage_named(board, "Spec")
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      view |> element("#stage-#{next_up.id}-down") |> render_click()

      assert has_element?(view, "#settings-group-planning #stage-#{next_up.id}-row")
      assert Boards.get_stage(board, next_up.id).category == :planning
      # one-directional: the stage it crossed past keeps its own category
      assert Boards.get_stage(board, spec.id).category == :planning

      view |> element("#stage-#{next_up.id}-up") |> render_click()

      assert has_element?(view, "#settings-group-unstarted #stage-#{next_up.id}-row")
      assert Boards.get_stage(board, next_up.id).category == :unstarted
    end

    test "the TYPE dropdown changes a stage's type and re-snaps a resident card's status",
         %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      card = insert(:card, stage: code, status: :working)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      assert has_element?(view, "#stage-#{code.id}-type-dropdown")

      view |> element("#stage-#{code.id}-type-review") |> render_click()

      assert Boards.get_stage(board, code.id).type == :review
      assert has_element?(view, "#stage-#{code.id}-row .stage-type-icon[data-type='review']")

      reloaded_card = Repo.get!(Schemas.Card, card.id)
      assert reloaded_card.status == :in_review
    end

    test "the AI-enabled toggle only renders for work/planning stages", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      review = stage_named(board, "Review")
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      assert has_element?(view, "#stage-#{code.id}-ai-toggle")
      refute has_element?(view, "#stage-#{review.id}-ai-toggle")

      view |> element("#stage-#{code.id}-ai-toggle") |> render_click()

      refute Boards.get_stage(board, code.id).ai_enabled
    end
  end

  describe "adding and deleting stages" do
    test "add stage creates a renamable default stage in that category",
         %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      view |> element("#add-stage-unstarted") |> render_click()

      new_stage = board |> Boards.list_stages() |> Enum.find(&(&1.name == "New stage"))
      assert new_stage.category == :unstarted
      assert new_stage.type == Schemas.Stage.default_type(:unstarted)
      assert has_element?(view, "#settings-group-unstarted #stage-#{new_stage.id}-row")
      assert has_element?(view, "#stage-#{new_stage.id}-name-display")
    end

    test "delete removes an empty stage", %{conn: conn, board: board} do
      deploy = stage_named(board, "Deploy")
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      view |> element("#stage-#{deploy.id}-delete") |> render_click()

      refute has_element?(view, "#stage-#{deploy.id}-row")
      assert Boards.get_stage(board, deploy.id) == nil
    end

    test "deleting a stage with cards flashes and deletes nothing", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      insert(:card, stage: code)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      html = view |> element("#stage-#{code.id}-delete") |> render_click()

      assert html =~ "still has cards"
      assert has_element?(view, "#stage-#{code.id}-row")
      assert Boards.get_stage(board, code.id)
    end

    test "deleting a stage whose sub-lane has cards flashes and deletes nothing",
         %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, review} = Boards.enable_lane(code, :review)
      insert(:card, stage: review)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      html = view |> element("#stage-#{code.id}-delete") |> render_click()

      assert html =~ "still has cards"
      assert Boards.get_stage(board, code.id)
    end

    test "deleting the only remaining stage flashes", %{conn: conn, board: board} do
      [keep | rest] = Enum.filter(board.stages, &is_nil(&1.parent_id))
      Enum.each(rest, fn stage -> {:ok, _} = Boards.delete_stage(stage) end)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")
      html = view |> element("#stage-#{keep.id}-delete") |> render_click()

      assert html =~ "at least one stage"
      assert Boards.get_stage(board, keep.id)
    end

    test "add stage to Planning creates a planning stage", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      view |> element("#add-stage-planning") |> render_click()

      new_stage = board |> Boards.list_stages() |> Enum.find(&(&1.name == "New stage"))
      assert new_stage.category == :planning
      assert has_element?(view, "#settings-group-planning #stage-#{new_stage.id}-row")
    end
  end

  describe "10b sub-lane toggles in the stage card" do
    test "the Done and Review toggles live inside the card and still drive lanes",
         %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      assert has_element?(view, "#stage-#{code.id}-sublanes #stage-#{code.id}-done-toggle")
      assert has_element?(view, "#stage-#{code.id}-sublanes #stage-#{code.id}-review-toggle")

      view |> element("#stage-#{code.id}-review-toggle") |> render_click()

      assert [%{type: :review}] = Boards.sublanes(code)
      assert has_element?(view, "#stage-#{code.id}-row", "always rejects back into its own stage")
    end

    test "the AI toggle reads AI-ENABLED and shows the violet listens-here pill when on",
         %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, _stage} = Boards.update_stage(code, %{ai_enabled: true})

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=stages")

      assert has_element?(view, "#settings-group-in_progress", "AI-ENABLED")
      refute has_element?(view, "#settings-group-in_progress", "RELAY AI")
      assert has_element?(view, "#stage-#{code.id}-ai-hint", "Relay AI listens here")

      view |> element("#stage-#{code.id}-ai-toggle") |> render_click()
      refute has_element?(view, "#stage-#{code.id}-ai-hint")
    end

    test "review and done sub-lane toggles both live in one dashed row, labeled SUB-LANE",
         %{conn: conn, board: board} do
      code = stage_named(board, "Code")

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=stages")

      assert has_element?(view, "#stage-#{code.id}-sublanes", "REVIEW SUB-LANE")
      assert has_element?(view, "#stage-#{code.id}-sublanes", "DONE SUB-LANE")
      refute has_element?(view, "#settings-group-in_progress", "DONE COLUMN")

      assert has_element?(view, "#stage-#{code.id}-sublanes [phx-value-lane='review']")
      assert has_element?(view, "#stage-#{code.id}-sublanes [phx-value-lane='done']")
    end
  end

  describe "reject route (ON REJECT, SEND TO)" do
    test "a top-level review stage shows the dropdown and persists a pick", %{conn: conn, board: board} do
      review = stage_named(board, "Review")
      plan = stage_named(board, "Plan")

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      assert has_element?(view, "#stage-#{review.id}-row", "ON REJECT, SEND TO")
      assert has_element?(view, "#stage-#{review.id}-reject-route")

      view |> element("#stage-#{review.id}-reject-to-#{plan.id}") |> render_click()

      assert Repo.get!(Schemas.Stage, review.id).reject_to_stage_id == plan.id
      assert has_element?(view, "#stage-#{review.id}-reject-route", "Plan")
    end

    test "a non-review stage shows no reject-route control", %{conn: conn, board: board} do
      code = stage_named(board, "Code")

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      refute has_element?(view, "#stage-#{code.id}-reject-route")
      refute has_element?(view, "#stage-#{code.id}-row", "ON REJECT, SEND TO")
    end

    test "a stage with a review sub-lane shows the fixed own-stage hint", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, _sublane} = Boards.enable_lane(code, :review)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      assert has_element?(
               view,
               "#stage-#{code.id}-row",
               "always rejects back into its own stage — nothing to configure"
             )
    end
  end
end
