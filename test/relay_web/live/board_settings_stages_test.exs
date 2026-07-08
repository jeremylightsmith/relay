defmodule RelayWeb.BoardSettingsStagesTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Repo
  alias Schemas.CardOwner

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  defp stage_named(board, name), do: Enum.find(board.stages, &(&1.name == name))

  describe "two-pane shell" do
    test "renders the rail with Stages active and stage cards grouped by category",
         %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/settings")

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
      assert has_element?(view, "#stage-#{code.id}-name[value='Code']")
      assert has_element?(view, "#stage-#{code.id}-description")
      assert has_element?(view, "#stage-#{code.id}-row .stage-owner-swatch[data-owner='ai']")
    end

    test "the API-key pane renders under the keys nav with its ids intact", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board/settings")

      view |> element("#settings-nav-keys") |> render_click()

      assert has_element?(view, "#api-key-pane")
      assert has_element?(view, "#generate-key")
      refute has_element?(view, "#stages-pane")

      view |> element("#settings-nav-stages") |> render_click()
      assert has_element?(view, "#stages-pane")
      refute has_element?(view, "#api-key-pane")
    end
  end

  describe "editing stages" do
    test "renaming persists and shows on a freshly mounted board", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, view, _html} = live(conn, ~p"/board/settings")

      view
      |> form("#stage-#{code.id}-form", stage: %{name: "Build"})
      |> render_change()

      assert Boards.get_stage(board, code.id).name == "Build"
      assert has_element?(view, "#stage-#{code.id}-name[value='Build']")

      {:ok, board_view, _html} = live(conn, ~p"/board")
      assert has_element?(board_view, "#stage-strip-#{code.id} h3", "Build")
    end

    test "a blank rename is rejected with a flash and keeps the old name",
         %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, view, _html} = live(conn, ~p"/board/settings")

      html = view |> form("#stage-#{code.id}-form", stage: %{name: ""}) |> render_change()

      assert html =~ "Stage name cannot be blank"
      assert Boards.get_stage(board, code.id).name == "Code"
    end

    test "the description input persists", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, view, _html} = live(conn, ~p"/board/settings")

      view
      |> form("#stage-#{code.id}-form", stage: %{description: "Agents write the code"})
      |> render_change()

      assert Boards.get_stage(board, code.id).description == "Agents write the code"
    end

    test "the arrows reorder stages and crossing a band adopts the category",
         %{conn: conn, board: board} do
      spec = stage_named(board, "Spec")
      plan = stage_named(board, "Plan")
      {:ok, view, _html} = live(conn, ~p"/board/settings")

      view |> element("#stage-#{spec.id}-down") |> render_click()

      assert has_element?(view, "#settings-group-planning #stage-#{spec.id}-row")
      assert Boards.get_stage(board, spec.id).category == :planning
      # one-directional: the old first-Planning stage keeps its category
      assert Boards.get_stage(board, plan.id).category == :planning

      view |> element("#stage-#{spec.id}-up") |> render_click()

      assert has_element?(view, "#settings-group-unstarted #stage-#{spec.id}-row")
      assert Boards.get_stage(board, spec.id).category == :unstarted
    end

    test "the owner segmented control changes meant-for and never touches card owners",
         %{conn: conn, board: board, user: user} do
      code = stage_named(board, "Code")
      card = insert(:card, stage: code)
      owner_row = insert(:card_owner, card: card, user: user)

      {:ok, view, _html} = live(conn, ~p"/board/settings")

      view |> element("#stage-#{code.id}-owner-human") |> render_click()

      assert Boards.get_stage(board, code.id).owner == :human
      assert has_element?(view, "#stage-#{code.id}-row .stage-owner-swatch[data-owner='human']")

      assert [%CardOwner{} = row] = Repo.all(CardOwner)
      assert row.id == owner_row.id
      assert row.actor_type == :user
      assert row.user_id == user.id
    end
  end

  describe "adding and deleting stages" do
    test "add stage creates a renamable default stage in that category",
         %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/settings")

      view |> element("#add-stage-unstarted") |> render_click()

      new_stage = board |> Boards.list_stages() |> Enum.find(&(&1.name == "New stage"))
      assert new_stage.category == :unstarted
      assert new_stage.owner == :human
      assert has_element?(view, "#settings-group-unstarted #stage-#{new_stage.id}-row")
      assert has_element?(view, "#stage-#{new_stage.id}-name")
    end

    test "delete removes an empty stage", %{conn: conn, board: board} do
      deploy = stage_named(board, "Deploy")
      {:ok, view, _html} = live(conn, ~p"/board/settings")

      view |> element("#stage-#{deploy.id}-delete") |> render_click()

      refute has_element?(view, "#stage-#{deploy.id}-row")
      assert Boards.get_stage(board, deploy.id) == nil
    end

    test "deleting a stage with cards flashes and deletes nothing", %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      insert(:card, stage: code)
      {:ok, view, _html} = live(conn, ~p"/board/settings")

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
      {:ok, view, _html} = live(conn, ~p"/board/settings")

      html = view |> element("#stage-#{code.id}-delete") |> render_click()

      assert html =~ "still has cards"
      assert Boards.get_stage(board, code.id)
    end

    test "deleting the only remaining stage flashes", %{conn: conn, board: board} do
      [keep | rest] = Enum.filter(board.stages, &(&1.lane == :main))
      Enum.each(rest, fn stage -> {:ok, _} = Boards.delete_stage(stage) end)

      {:ok, view, _html} = live(conn, ~p"/board/settings")
      html = view |> element("#stage-#{keep.id}-delete") |> render_click()

      assert html =~ "at least one stage"
      assert Boards.get_stage(board, keep.id)
    end
  end

  describe "10b sub-lane toggles in the stage card" do
    test "the Done and Review toggles live inside the card and still drive lanes",
         %{conn: conn, board: board} do
      code = stage_named(board, "Code")
      {:ok, view, _html} = live(conn, ~p"/board/settings")

      assert has_element?(view, "#stage-#{code.id}-row #stage-#{code.id}-done-toggle")
      assert has_element?(view, "#stage-#{code.id}-row #stage-#{code.id}-review-toggle")

      view |> element("#stage-#{code.id}-review-toggle") |> render_click()

      assert [%{lane: :review}] = Boards.sublanes(code)
      assert has_element?(view, "#stage-#{code.id}-row", "Finished work waits in")
    end
  end
end
