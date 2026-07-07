defmodule RelayWeb.BoardLiveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Boards.Board
  alias Relay.Boards.Stage
  alias Relay.Cards
  alias Relay.Cards.Card
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

  describe "cards" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog | _rest] = board.stages
      %{board: board, backlog: backlog}
    end

    test "a stage's compose CTA reveals the composer for that stage only", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      refute has_element?(view, "#stage-col-1-compose-form")

      view |> element("#stage-col-1-new-card") |> render_click()

      assert has_element?(view, "#stage-col-1-compose-form")
      refute has_element?(view, "#stage-col-2-compose-form")
    end

    test "submitting the composer creates a card in that stage and clears the input",
         %{conn: conn, backlog: backlog} do
      {:ok, view, _html} = live(conn, ~p"/board")

      view |> element("#stage-col-1-new-card") |> render_click()

      view
      |> form("#stage-col-1-compose-form", card: %{title: "Ship MMF 03"})
      |> render_submit()

      assert has_element?(view, "#stage-col-1-cards .board-card", "Ship MMF 03")

      assert [card] = Repo.all(Card)
      assert card.stage_id == backlog.id
      assert card.title == "Ship MMF 03"
      assert card.ref_number == 1

      assert has_element?(view, "#stage-col-1-compose-form")

      input_html =
        view
        |> element("#stage-col-1-compose-form input[name='card[title]']")
        |> render()

      refute input_html =~ "Ship MMF 03"
    end

    test "creating cards assigns per-board incrementing refs shown on the cards", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      view |> element("#stage-col-1-new-card") |> render_click()
      view |> form("#stage-col-1-compose-form", card: %{title: "First"}) |> render_submit()
      view |> form("#stage-col-1-compose-form", card: %{title: "Second"}) |> render_submit()

      assert has_element?(view, "#stage-col-1-cards .board-card .card-ref", "RLY-1")
      assert has_element?(view, "#stage-col-1-cards .board-card .card-ref", "RLY-2")
    end

    test "cards persist and re-render in position order on reload", %{conn: conn, backlog: backlog} do
      insert(:card, stage: backlog, title: "Second", position: 2, ref_number: 2)
      insert(:card, stage: backlog, title: "First", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board")

      titles =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#stage-col-1-cards .board-card .card-title")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert titles == ["First", "Second"]
    end

    test "cards render in their own stage; other stages keep the empty state",
         %{conn: conn, backlog: backlog} do
      insert(:card, stage: backlog, title: "Only here", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#stage-col-1-cards .board-card", "Only here")
      refute has_element?(view, "#stage-col-2-cards .board-card")
      assert has_element?(view, "#stage-col-2-cards .stage-empty")
    end

    test "cancel closes the composer without creating a card", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      view |> element("#stage-col-1-new-card") |> render_click()
      view |> element("#stage-col-1-composer button", "Cancel") |> render_click()

      refute has_element?(view, "#stage-col-1-compose-form")
      assert Repo.all(Card) == []
    end

    test "submitting a blank title keeps the composer open and creates nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      view |> element("#stage-col-1-new-card") |> render_click()
      view |> form("#stage-col-1-compose-form", card: %{title: ""}) |> render_submit()

      assert has_element?(view, "#stage-col-1-compose-form")
      assert Repo.all(Card) == []
    end
  end

  describe "card drawer" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog | _rest] = board.stages
      {:ok, card} = Cards.create_card(backlog, %{title: "Draft the spec", tag: "spec"})
      %{board: board, backlog: backlog, card: card}
    end

    test "no drawer renders without a card param", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      refute has_element?(view, "#card-drawer")
    end

    test "clicking a board card patches to its ref and opens the drawer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      view |> element("#stage-col-1-cards .board-card") |> render_click()

      assert_patch(view, ~p"/board?card=RLY-1")
      assert has_element?(view, "#card-drawer")
      assert has_element?(view, "#card-drawer-title-input[value='Draft the spec']")
      assert has_element?(view, "#card-drawer .drawer-card-ref", "RLY-1")
    end

    test "the drawer header shows the stage chip in the owner color", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer .drawer-stage-chip.badge-primary", "Backlog")
    end

    test "the properties rail shows stage, tags, and dates", %{conn: conn, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer-rail .rail-stage", "Backlog")
      assert has_element?(view, "#card-drawer-rail .rail-tags", "spec")

      assert has_element?(
               view,
               "#card-drawer-rail .rail-dates",
               Calendar.strftime(card.inserted_at, "%b %d, %Y")
             )
    end

    test "visiting the deep link opens the drawer directly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer")
      assert has_element?(view, "#card-drawer .drawer-card-ref", "RLY-1")
    end

    test "the close button clears the param and closes the drawer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-close") |> render_click()

      assert_patch(view, ~p"/board")
      refute has_element?(view, "#card-drawer")
    end

    test "clicking the scrim clears the param and closes the drawer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-scrim") |> render_click()

      assert_patch(view, ~p"/board")
      refute has_element?(view, "#card-drawer")
    end

    test "an unknown or malformed ref renders no drawer", %{conn: conn} do
      for ref <- ["RLY-999", "banana", "RLY-abc"] do
        {:ok, view, _html} = live(conn, ~p"/board?card=#{ref}")

        refute has_element?(view, "#card-drawer")
        assert has_element?(view, "#board")
      end
    end

    test "a ref for another user's card does not open the drawer", %{conn: conn} do
      other_stage = insert(:stage)
      insert(:card, stage: other_stage, title: "Theirs", ref_number: 2, position: 1)

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-2")

      refute has_element?(view, "#card-drawer")
      assert has_element?(view, "#board")
    end
  end

  describe "top bar" do
    test "shows the avatar image and a sign out link", %{conn: conn} do
      user = insert(:user, avatar_url: "https://example.com/me.png")
      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/board")

      assert has_element?(view, "#user-avatar img")
      assert has_element?(view, "#sign-out")
    end

    test "falls back to initials when the user has no avatar image", %{conn: conn} do
      user = insert(:user, avatar_url: nil, name: "Ada Lovelace")
      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/board")

      refute has_element?(view, "#user-avatar img")
      assert has_element?(view, "#user-avatar", "AL")
    end
  end

  describe "signing out" do
    test "after sign out, the board route requires signing in again", %{conn: conn} do
      user = insert(:user)
      conn = conn |> log_in_user(user) |> delete(~p"/logout")

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/board")
    end
  end
end
