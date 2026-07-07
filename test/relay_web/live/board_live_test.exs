defmodule RelayWeb.BoardLiveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards.Board
  alias Relay.Boards.Stage
  alias Relay.Repo

  describe "when logged out" do
    test "GET /board redirects to the sign-in page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/board")
    end
  end

  describe "when logged in" do
    setup :register_and_log_in_user

    test "provisions the default board with 7 stages on first visit", %{conn: conn, user: user} do
      {:ok, _view, _html} = live(conn, ~p"/board")

      assert [%Board{} = board] = Repo.all(Board)
      assert board.owner_id == user.id
      assert Repo.aggregate(Stage, :count) == 7
    end

    test "revisiting does not create a duplicate board", %{conn: conn} do
      {:ok, _view, _html} = live(conn, ~p"/board")
      {:ok, _view, _html} = live(conn, ~p"/board")

      assert Repo.aggregate(Board, :count) == 1
      assert Repo.aggregate(Stage, :count) == 7
    end

    test "renders the stage columns in position order", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      names =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#board .stage-column h3")
        |> Enum.map(&LazyHTML.text/1)

      assert names == ["Backlog", "Spec", "Plan", "Code", "Review", "Deploy", "Done"]
    end

    test "groups the stages under their category bands in order", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#category-unstarted h2.category-band", "Unstarted")
      assert has_element?(view, "#category-in_progress h2.category-band", "In progress")
      assert has_element?(view, "#category-complete h2.category-band", "Complete")

      assert has_element?(view, "#category-unstarted #stage-col-1", "Backlog")
      assert has_element?(view, "#category-unstarted #stage-col-2", "Spec")
      assert has_element?(view, "#category-in_progress #stage-col-3", "Plan")
      assert has_element?(view, "#category-in_progress #stage-col-4", "Code")
      assert has_element?(view, "#category-in_progress #stage-col-5", "Review")
      assert has_element?(view, "#category-in_progress #stage-col-6", "Deploy")
      assert has_element?(view, "#category-complete #stage-col-7", "Done")

      bands =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#board .category-band")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert bands == ["Unstarted", "In progress", "Complete"]
    end

    test "shows the right Human/AI owner pill on each stage", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      for position <- [1, 2, 5, 7] do
        assert has_element?(view, "#stage-col-#{position} .owner-pill.badge-primary", "Human")
      end

      for position <- [3, 4, 6] do
        assert has_element?(view, "#stage-col-#{position} .owner-pill.badge-secondary", "AI")
      end
    end

    test "every stage shows the empty-state placeholder", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      empties =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#board .stage-empty")
        |> Enum.count()

      assert empties == 7
    end
  end
end
