defmodule RelayWeb.BoardLiveTest do
  use RelayWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Repo
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.CardOwner
  alias Schemas.Comment
  alias Schemas.Stage

  describe "when logged out" do
    test "GET /board/:slug redirects to the sign-in page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/board/anything")
    end
  end

  describe "when logged in" do
    setup :register_and_log_in_user

    test "provisions the default board with 8 stages on first visit", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, _view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert [%Board{} = board] = Repo.all(Board)
      assert board.owner_id == user.id
      assert Repo.aggregate(Stage, :count) == 8
    end

    test "revisiting does not create a duplicate board", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, _view, _html} = live(conn, ~p"/board/#{board.slug}")
      {:ok, _view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert Repo.aggregate(Board, :count) == 1
      assert Repo.aggregate(Stage, :count) == 8
    end

    test "renders the stage columns in position order", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      names =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#board .stage-column h3")
        |> Enum.map(&String.trim(LazyHTML.text(&1)))

      assert names == ["Backlog", "Next up", "Spec", "Plan", "Code", "Review", "Deploy", "Done"]
    end

    test "groups the stages under their category bands in order", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
      next_up = Enum.find(board.stages, &(&1.name == "Next up"))
      spec = Enum.find(board.stages, &(&1.name == "Spec"))
      plan = Enum.find(board.stages, &(&1.name == "Plan"))
      code = Enum.find(board.stages, &(&1.name == "Code"))
      review = Enum.find(board.stages, &(&1.name == "Review"))
      deploy = Enum.find(board.stages, &(&1.name == "Deploy"))
      done = Enum.find(board.stages, &(&1.name == "Done"))

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#category-unstarted h2.category-band", "Unstarted")
      assert has_element?(view, "#category-planning h2.category-band", "Planning")
      assert has_element?(view, "#category-in_progress h2.category-band", "In progress")
      assert has_element?(view, "#category-complete h2.category-band", "Complete")

      # a fresh board is empty, so every stage renders as its collapsed strip
      assert has_element?(view, "#category-unstarted #stage-strip-#{backlog.id}", "Backlog")
      assert has_element?(view, "#category-unstarted #stage-strip-#{next_up.id}", "Next up")
      assert has_element?(view, "#category-planning #stage-strip-#{spec.id}", "Spec")
      assert has_element?(view, "#category-planning #stage-strip-#{plan.id}", "Plan")
      assert has_element?(view, "#category-in_progress #stage-strip-#{code.id}", "Code")
      assert has_element?(view, "#category-in_progress #stage-strip-#{review.id}", "Review")
      assert has_element?(view, "#category-in_progress #stage-strip-#{deploy.id}", "Deploy")
      assert has_element?(view, "#category-complete #stage-strip-#{done.id}", "Done")

      bands =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#board .category-band")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert bands == ["Unstarted", "Planning", "In progress", "Complete"]
    end

    test "renders the Planning band with its label and violet dot", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      plan = Enum.find(board.stages, &(&1.name == "Plan"))

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#category-planning h2.category-band", "Planning")
      assert has_element?(view, "#category-planning #stage-strip-#{plan.id}", "Plan")

      [style] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#category-planning .category-dot")
        |> LazyHTML.attribute("style")

      assert style =~ "--color-secondary"
    end

    test "shows the right stage-type icon on each stage", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      for stage <- board.stages do
        assert has_element?(
                 view,
                 ~s(#stage-strip-#{stage.id} .stage-type-icon[data-type="#{stage.type}"])
               )
      end
    end

    test "a fresh board collapses every empty stage to a strip", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      document = view |> render() |> LazyHTML.from_fragment()

      assert document |> LazyHTML.query("#board .stage-strip") |> Enum.count() == 8
      assert document |> LazyHTML.query("#board .stage-empty") |> Enum.count() == 0
    end
  end

  describe "cards" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog | _rest] = board.stages
      %{board: board, backlog: backlog}
    end

    test "a stage's compose CTA reveals the composer for that stage only", %{conn: conn, backlog: backlog, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      expand_stage(view, backlog)

      refute has_element?(view, "#stage-col-1-compose-form")

      view |> element("#stage-col-1-new-card") |> render_click()

      assert has_element?(view, "#stage-col-1-compose-form")
      refute has_element?(view, "#stage-col-2-compose-form")
    end

    test "submitting the composer creates a card in that stage and clears the input",
         %{conn: conn, backlog: backlog, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      expand_stage(view, backlog)
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

    test "creating cards assigns per-board incrementing refs shown on the cards", %{
      conn: conn,
      backlog: backlog,
      user: user
    } do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      expand_stage(view, backlog)
      view |> element("#stage-col-1-new-card") |> render_click()
      view |> form("#stage-col-1-compose-form", card: %{title: "First"}) |> render_submit()
      view |> form("#stage-col-1-compose-form", card: %{title: "Second"}) |> render_submit()

      assert has_element?(view, "#stage-col-1-cards .board-card .card-ref", "RLY-1")
      assert has_element?(view, "#stage-col-1-cards .board-card .card-ref", "RLY-2")
    end

    test "cards persist and re-render in position order on reload", %{conn: conn, backlog: backlog, user: user} do
      insert(:card, stage: backlog, title: "Second", position: 2, ref_number: 2)
      insert(:card, stage: backlog, title: "First", position: 1, ref_number: 1)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      titles =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#stage-col-1-cards .board-card .card-title")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert titles == ["First", "Second"]
    end

    test "cards render in their own stage; other stages keep the empty state",
         %{conn: conn, backlog: backlog, board: board} do
      [_backlog, spec | _rest] = board.stages
      insert(:card, stage: backlog, title: "Only here", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-col-1-cards .board-card", "Only here")
      refute has_element?(view, "#stage-col-2-cards .board-card")
      assert has_element?(view, "#stage-strip-#{spec.id} .stage-count", "0")
    end

    test "cancel closes the composer without creating a card", %{conn: conn, backlog: backlog, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      expand_stage(view, backlog)
      view |> element("#stage-col-1-new-card") |> render_click()
      view |> element("#stage-col-1-composer button", "Cancel") |> render_click()

      refute has_element?(view, "#stage-col-1-compose-form")
      assert Repo.all(Card) == []
    end

    test "submitting a blank title keeps the composer open and creates nothing", %{
      conn: conn,
      backlog: backlog,
      user: user
    } do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      expand_stage(view, backlog)
      view |> element("#stage-col-1-new-card") |> render_click()
      view |> form("#stage-col-1-compose-form", card: %{title: ""}) |> render_submit()

      assert has_element?(view, "#stage-col-1-compose-form")
      assert Repo.all(Card) == []
    end

    test "creating a card inserts it at the top of the stream", %{conn: conn, backlog: backlog, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      expand_stage(view, backlog)
      view |> element("#stage-col-1-new-card") |> render_click()
      view |> form("#stage-col-1-compose-form", card: %{title: "First"}) |> render_submit()
      view |> form("#stage-col-1-compose-form", card: %{title: "Second"}) |> render_submit()

      assert stage_titles(view, 1) == ["Second", "First"]

      {:ok, reloaded, _html} = live(conn, ~p"/board/#{board.slug}")
      assert stage_titles(reloaded, 1) == ["Second", "First"]
    end

    test "creating a card pushes a focus event carrying the new card's ref",
         %{conn: conn, backlog: backlog, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      expand_stage(view, backlog)
      view |> element("#stage-col-1-new-card") |> render_click()
      view |> form("#stage-col-1-compose-form", card: %{title: "Focus me"}) |> render_submit()

      assert_push_event(view, "focus_card", %{ref: "RLY-1"})
    end
  end

  describe "lane counts" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog | _rest] = board.stages
      %{board: board, backlog: backlog}
    end

    test "every stage renders its card count", %{conn: conn, board: board, backlog: backlog} do
      insert(:card, stage: backlog, title: "One", position: 1, ref_number: 1)
      insert(:card, stage: backlog, title: "Two", position: 2, ref_number: 2)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-col-1 .stage-count", "2")

      for stage <- tl(board.stages) do
        assert has_element?(view, "#stage-strip-#{stage.id} .stage-count", "0")
      end
    end

    test "creating a card bumps its stage's count", %{conn: conn, board: board, backlog: backlog} do
      [_backlog, spec | _rest] = board.stages

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      expand_stage(view, backlog)
      view |> element("#stage-col-1-new-card") |> render_click()
      view |> form("#stage-col-1-compose-form", card: %{title: "Count me"}) |> render_submit()

      assert has_element?(view, "#stage-col-1 .stage-count", "1")
      assert has_element?(view, "#stage-strip-#{spec.id} .stage-count", "0")
    end
  end

  describe "moving cards" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog, spec | _rest] = board.stages
      plan = Enum.find(board.stages, &(&1.name == "Plan"))
      %{board: board, backlog: backlog, spec: spec, plan: plan}
    end

    test "a move_card event moves the card to the target stage and persists across reloads",
         %{conn: conn, backlog: backlog, spec: spec, user: user} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Take the baton"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => 0})

      assert has_element?(view, "#stage-col-2-cards .board-card", "Take the baton")
      refute has_element?(view, "#stage-col-1-cards .board-card")
      assert Repo.get!(Card, card.id).stage_id == spec.id

      {:ok, reloaded, _html} = live(conn, ~p"/board/#{board.slug}")
      assert has_element?(reloaded, "#stage-col-2-cards .board-card", "Take the baton")
    end

    test "moving updates both lane counts", %{conn: conn, backlog: backlog, spec: spec, user: user} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Mover"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => 0})

      assert has_element?(view, "#stage-strip-#{backlog.id} .stage-count", "0")
      assert has_element?(view, "#stage-col-2 .stage-count", "1")
    end

    test "reordering within a stage persists the new order across reloads",
         %{conn: conn, backlog: backlog, user: user} do
      {:ok, _first} = Cards.create_card(backlog, %{title: "First"})
      {:ok, _second} = Cards.create_card(backlog, %{title: "Second"})
      {:ok, _third} = Cards.create_card(backlog, %{title: "Third"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => backlog.id, "index" => 0})

      assert stage_titles(view, 1) == ["First", "Third", "Second"]

      {:ok, reloaded, _html} = live(conn, ~p"/board/#{board.slug}")
      assert stage_titles(reloaded, 1) == ["First", "Third", "Second"]
    end

    test "accepts string stage_id and index (phx-value parity)",
         %{conn: conn, backlog: backlog, spec: spec, user: user} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Stringly"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      render_hook(view, "move_card", %{
        "ref" => "RLY-1",
        "stage_id" => Integer.to_string(spec.id),
        "index" => "0"
      })

      assert Repo.get!(Card, card.id).stage_id == spec.id
    end

    test "omitting index appends the card to the bottom of the target stage",
         %{conn: conn, backlog: backlog, spec: spec, user: user} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Mover"})
      {:ok, existing} = Cards.create_card(spec, %{title: "Already there"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id})

      assert Repo.get!(Card, card.id).position == 2
      assert Repo.get!(Card, existing.id).position == 1
      assert stage_titles(view, 2) == ["Already there", "Mover"]
    end

    test "a ref that is not on this board is rejected", %{conn: conn, spec: spec, user: user} do
      other_stage = insert(:stage)
      theirs = insert(:card, stage: other_stage, title: "Theirs", position: 1, ref_number: 1)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => 0})

      assert Repo.get!(Card, theirs.id).stage_id == other_stage.id
      refute has_element?(view, "#stage-col-2-cards .board-card")
    end

    test "a target stage that is not on this board is rejected",
         %{conn: conn, backlog: backlog, user: user} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Stay home"})
      other_stage = insert(:stage)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => other_stage.id, "index" => 0})

      assert Repo.get!(Card, card.id).stage_id == backlog.id
      assert has_element?(view, "#stage-col-1-cards .board-card", "Stay home")
    end

    test "garbage stage_id or index is ignored", %{conn: conn, backlog: backlog, spec: spec, user: user} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Unmoved"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => "banana", "index" => 0})
      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => "banana"})

      assert Repo.get!(Card, card.id).stage_id == backlog.id
      assert has_element?(view, "#stage-col-1-cards .board-card", "Unmoved")
    end

    test "moving the drawer-selected card refreshes the drawer's stage chip",
         %{conn: conn, backlog: backlog, plan: plan, user: user} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Chip check"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => plan.id, "index" => 0})

      assert has_element?(view, "#card-drawer .drawer-stage-chip.badge-secondary", "Plan")
    end
  end

  describe "drag-and-drop wiring" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog | _rest] = board.stages
      {:ok, _card} = Cards.create_card(backlog, %{title: "Drag me"})
      %{board: board, backlog: backlog}
    end

    test "the board mounts the BoardDnD hook", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#board[phx-hook='BoardDnD']")
    end

    test "cards are draggable and carry their ref", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-col-1-cards .board-card[draggable='true'][data-ref='RLY-1']")
    end

    test "every stage's card container is a drop zone carrying its stage id",
         %{conn: conn, backlog: backlog, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-col-1-cards.stage-cards[data-stage-id='#{backlog.id}']")

      zones =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#board .stage-cards[data-stage-id]")
        |> Enum.count()

      assert zones == 8
    end
  end

  describe "baton rendering on the board" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog, _spec, plan | _rest] = board.stages
      {:ok, card} = Cards.create_card(backlog, %{title: "Baton card"})
      %{board: board, backlog: backlog, plan: plan, card: card}
    end

    test "an unowned card renders neutral: transparent accent, no owners, no mismatch", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-col-1-cards .board-card.border-l-base-300", "Baton card")
      refute has_element?(view, "#stage-col-1-cards .board-card .card-owners")
      refute has_element?(view, "#stage-col-1-cards .board-card .card-status")
      refute has_element?(view, "#stage-col-1-cards .board-card .card-mismatch")
    end

    test "an unowned card in an AI stage shows no mismatch", %{conn: conn, plan: plan, user: user} do
      {:ok, _card} = Cards.create_card(plan, %{title: "Unowned in Plan"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      refute has_element?(view, "#stage-col-3-cards .board-card .card-mismatch")
    end

    test "a human-owned card renders blue with a human owner avatar",
         %{conn: conn, user: user, card: card} do
      {:ok, _card} = Cards.add_owner(card, {:user, user.id})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(
               view,
               "#stage-col-1-cards .board-card[data-active-owner='human'].border-l-primary"
             )

      assert has_element?(
               view,
               ~s(#stage-col-1-cards .board-card .card-owners [data-actor-type="user"])
             )
    end

    test "adding the agent as an owner flips the card to violet AI",
         %{conn: conn, user: user, card: card, plan: plan} do
      {:ok, card} = Cards.add_owner(card, {:user, user.id})
      {:ok, card} = Cards.add_owner(card, :agent)

      # Backlog (stage-col-1) is a human-owned stage, so an AI-active card
      # left there is a genuine stage mismatch (covered separately by "an
      # AI-active card in a human stage shows the red meant-for-humans
      # warning") and the mismatch rule overrides the border to
      # border-l-error. Move the card into Plan — an AI-owned stage — so
      # this test can demonstrate the clean, no-mismatch violet-AI border.
      {:ok, _moved} = Cards.move_card(card, plan, 0)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(
               view,
               "#stage-col-3-cards .board-card[data-active-owner='ai'].border-l-secondary"
             )

      assert has_element?(
               view,
               ~s(#stage-col-3-cards .board-card .card-owners [data-actor-type="agent"])
             )
    end

    test "a needs_input card shows the amber NEEDS INPUT box", %{conn: conn, card: card, user: user} do
      {:ok, _card} = Cards.set_status(card, %{"status" => "needs_input"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(
               view,
               "#stage-col-1-cards .board-card.border-l-warning .card-needs-input",
               "NEEDS INPUT"
             )
    end

    test "a working card shows its progress in the status line", %{conn: conn, card: card, user: user} do
      {:ok, _card} = Cards.set_status(card, %{"status" => "working", "progress" => "61"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(
               view,
               "#stage-col-1-cards .board-card .card-status[data-status='working']",
               "working · 61%"
             )
    end

    test "a human-active card in an AI stage shows the red meant-for-agents warning",
         %{conn: conn, user: user, card: card, plan: plan} do
      {:ok, card} = Cards.add_owner(card, {:user, user.id})
      {:ok, _moved} = Cards.move_card(card, plan, 0)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(
               view,
               "#stage-col-3-cards .board-card.border-l-error .card-mismatch",
               "meant to be used by agents"
             )
    end

    test "an AI-active card in a human stage shows the red meant-for-humans warning",
         %{conn: conn, card: card, user: user} do
      {:ok, _card} = Cards.add_owner(card, :agent)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(
               view,
               "#stage-col-1-cards .board-card.border-l-error .card-mismatch",
               "meant for humans"
             )
    end

    test "moving a card changes neither its owners nor its status",
         %{conn: conn, board: board, user: user, card: card, plan: plan} do
      {:ok, _card} = Cards.add_owner(card, {:user, user.id})

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => plan.id, "index" => 0})

      moved = Cards.get_card_by_ref(board, "RLY-1")
      assert moved.stage_id == plan.id
      assert moved.status == :queued
      assert [%{actor_type: :user}] = moved.owners

      assert has_element?(
               view,
               "#stage-col-3-cards .board-card.border-l-error .card-mismatch",
               "meant to be used by agents"
             )
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

    test "no drawer renders without a card param", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      refute has_element?(view, "#card-drawer")
    end

    test "clicking a board card patches to its ref and opens the drawer", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view |> element("#stage-col-1-cards .board-card") |> render_click()

      assert_patch(view, ~p"/board/#{board.slug}?card=RLY-1")
      assert has_element?(view, "#card-drawer")
      assert has_element?(view, "#card-drawer-title-display", "Draft the spec")
      assert has_element?(view, "#card-drawer .drawer-card-ref", "RLY-1")
    end

    test "the drawer header shows the stage chip in the owner color", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer .drawer-stage-chip.badge-primary", "Backlog")
    end

    test "the properties rail shows stage, tags, and dates", %{conn: conn, card: card, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer-rail .rail-stage", "Backlog")
      assert has_element?(view, "#card-drawer-rail .rail-tags", "spec")

      assert has_element?(
               view,
               "#card-drawer-rail .rail-dates",
               Calendar.strftime(card.inserted_at, "%b %d, %Y")
             )
    end

    test "renders description, spec, plan, and comments as markdown-rendered HTML",
         %{conn: conn, card: card, user: user} do
      {:ok, _updated} =
        Cards.update_card(card, %{
          description: "## Desc head\n\n**descbold**",
          spec: "## Spec head\n\n**specbold**",
          plan: "## Plan head\n\n**planbold**"
        })

      {:ok, _comment} =
        Relay.Activity.add_comment(card, %{actor: {:user, user.id}, body: "**commentbold** note"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      # each long-form field is markdown turned into HTML, not literal text
      assert has_element?(view, "#card-drawer-description-view h2", "Desc head")
      assert has_element?(view, "#card-drawer-description-view strong", "descbold")
      assert has_element?(view, "#card-drawer-spec-view strong", "specbold")
      assert has_element?(view, "#card-plan-body strong", "planbold")
      assert has_element?(view, ".timeline-comment-body strong", "commentbold")
    end

    test "spec and plan sit collapsed between Description and Conversation",
         %{conn: conn, card: card, user: user} do
      {:ok, _updated} = Cards.update_card(card, %{spec: "The spec body", plan: "The plan body"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      # both are <details> wrappers around the preserved content ids
      assert has_element?(view, "details#card-drawer-spec #card-drawer-spec-view")
      assert has_element?(view, "details#card-plan #card-plan-body")

      # collapsed by default — neither has the open attribute
      refute has_element?(view, "details#card-drawer-spec[open]")
      refute has_element?(view, "details#card-plan[open]")

      # DOM order (mockup order): Description → Spec → Plan → Conversation → Activity
      description = index_of(html, ~s(id="card-drawer-description"))
      spec = index_of(html, ~s(id="card-drawer-spec"))
      plan = index_of(html, ~s(id="card-plan"))
      conv = index_of(html, ~s(id="card-drawer-conversation"))
      activity = index_of(html, ~s(id="card-drawer-activity"))

      assert description < spec
      assert spec < plan
      assert plan < conv
      assert conv < activity
    end

    test "a long title wraps in the read display (no truncation)",
         %{conn: conn, card: card, user: user} do
      long = String.duplicate("word ", 40)
      {:ok, _} = Cards.update_card(card, %{title: long})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer-title-display.break-words")
      assert has_element?(view, "#card-drawer-title-display .whitespace-pre-wrap")
      refute has_element?(view, "#card-drawer-title-display.truncate")
    end

    test "the main column renders sections in mockup order", %{conn: conn, card: card, user: user} do
      {:ok, _} =
        Cards.update_card(card, %{
          description: "A description",
          spec: "# Spec body",
          plan: "# Plan body",
          ai_result: %{"summary" => "AI summary"}
        })

      insert(:sub_task, card: card, title: "st-1")

      board = Boards.get_or_create_default_board(user)
      {:ok, _view, html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      order = ~w(
        card-drawer-description
        card-drawer-spec
        card-plan
        ai-result
        sub-tasks
        card-drawer-conversation
        card-drawer-activity
      )

      positions =
        Enum.map(order, fn id ->
          {pos, _len} = :binary.match(html, ~s(id="#{id}"))
          pos
        end)

      assert positions == Enum.sort(positions),
             "main-column sections are out of mockup order: #{inspect(Enum.zip(order, positions))}"
    end

    test "with a spec but no plan, only the Spec block appears before Activity",
         %{conn: conn, card: card, user: user} do
      {:ok, _updated} = Cards.update_card(card, %{spec: "Spec only"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "details#card-drawer-spec #card-drawer-spec-view")
      refute has_element?(view, "#card-plan")

      spec = index_of(html, ~s(id="card-drawer-spec"))
      activity = index_of(html, ~s(id="card-drawer-activity"))
      assert spec < activity
    end

    test "with neither spec nor plan, nothing renders between Conversation and Activity",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      refute has_element?(view, "#card-drawer-spec-view")
      refute has_element?(view, "#card-plan")
    end

    test "visiting the deep link opens the drawer directly", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer")
      assert has_element?(view, "#card-drawer .drawer-card-ref", "RLY-1")
    end

    test "the close button clears the param and closes the drawer", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view |> element("#card-drawer-close") |> render_click()

      assert_patch(view, ~p"/board/#{board.slug}")
      refute has_element?(view, "#card-drawer")
    end

    test "clicking the scrim clears the param and closes the drawer", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view |> element("#card-drawer-scrim") |> render_click()

      assert_patch(view, ~p"/board/#{board.slug}")
      refute has_element?(view, "#card-drawer")
    end

    test "an unknown or malformed ref renders no drawer", %{conn: conn, user: user} do
      for ref <- ["RLY-999", "banana", "RLY-abc"] do
        board = Boards.get_or_create_default_board(user)
        {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")

        refute has_element?(view, "#card-drawer")
        assert has_element?(view, "#board")
      end
    end

    test "a ref for another user's card does not open the drawer", %{conn: conn, user: user} do
      other_stage = insert(:stage)
      insert(:card, stage: other_stage, title: "Theirs", ref_number: 2, position: 1)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-2")

      refute has_element?(view, "#card-drawer")
      assert has_element?(view, "#board")
    end

    test "the title shows as read-only text until clicked", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer-title-display", "Draft the spec")
      refute has_element?(view, "#card-drawer-title-form")
    end

    test "clicking the title opens the inline editor", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view |> element("#card-drawer-title-display") |> render_click()

      assert has_element?(view, "#card-drawer-title-form textarea#card-drawer-title-input")
    end

    test "saving the title persists and reflects on drawer and board card",
         %{conn: conn, card: card, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view |> element("#card-drawer-title-display") |> render_click()
      view |> form("#card-drawer-title-form", card: %{title: "Sharper title"}) |> render_submit()

      assert Repo.get!(Card, card.id).title == "Sharper title"
      assert has_element?(view, "#card-drawer-title-display", "Sharper title")
      refute has_element?(view, "#card-drawer-title-form")
      assert has_element?(view, "#stage-col-1-cards .board-card .card-title", "Sharper title")
      refute has_element?(view, "#stage-col-1-cards .board-card .card-title", "Draft the spec")
    end

    test "a blank title is rejected with an error and nothing changes", %{conn: conn, card: card, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view |> element("#card-drawer-title-display") |> render_click()
      view |> form("#card-drawer-title-form", card: %{title: ""}) |> render_submit()

      assert has_element?(view, "#card-drawer-title-form", "can't be blank")
      assert Repo.get!(Card, card.id).title == "Draft the spec"
    end

    test "a long title wraps in the header rather than scrolling one line",
         %{conn: conn, card: card, user: user} do
      {:ok, _} = Cards.update_card(card, %{title: String.duplicate("verylongword ", 15)})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer-title-display.break-words")
      assert has_element?(view, "#card-drawer-title-display .whitespace-pre-wrap")
    end

    test "pressing Escape closes the open drawer", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer")

      view |> element("#card-drawer") |> render_keydown(%{"key" => "Escape"})

      assert_patch(view, ~p"/board/#{board.slug}")
      refute has_element?(view, "#card-drawer")
    end

    test "no window-keydown close binding exists when no card is open", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      refute has_element?(view, "#card-drawer")
      refute has_element?(view, "[phx-window-keydown='close_drawer']")
    end

    test "clicking the description area opens the textarea editor", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer-description-display", "Add a description")
      refute has_element?(view, "#card-drawer-description-form")

      view |> element("#card-drawer-description-display") |> render_click()

      assert has_element?(
               view,
               "#card-drawer-description-form textarea#card-drawer-description-input"
             )
    end

    test "saving the description persists and renders it as markdown",
         %{conn: conn, card: card, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view |> element("#card-drawer-description-display") |> render_click()

      view
      |> form("#card-drawer-description-form", card: %{description: "Line one\n\nLine two"})
      |> render_submit()

      refute has_element?(view, "#card-drawer-description-form")
      # a blank line is markdown for two paragraphs, rendered as HTML
      assert has_element?(view, "#card-drawer-description-view.md p", "Line one")
      assert has_element?(view, "#card-drawer-description-view.md p", "Line two")
      assert Repo.get!(Card, card.id).description == "Line one\n\nLine two"
    end

    test "cancel closes the editor without saving", %{conn: conn, card: card, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view |> element("#card-drawer-description-display") |> render_click()
      view |> element("#card-drawer-description-cancel") |> render_click()

      refute has_element?(view, "#card-drawer-description-form")
      assert has_element?(view, "#card-drawer-description-display", "Add a description")
      assert Repo.get!(Card, card.id).description == nil
    end

    test "a saved description survives a fresh deep-link visit", %{conn: conn, card: card, user: user} do
      {:ok, _card} = Cards.update_card(card, %{description: "Persisted\ntext"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer-description-view")
      assert view |> element("#card-drawer-description-view") |> render() =~ "Persisted\ntext"
    end

    test "editing pre-fills the textarea with the current description", %{conn: conn, card: card, user: user} do
      {:ok, _card} = Cards.update_card(card, %{description: "Current text"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
      view |> element("#card-drawer-description-display") |> render_click()

      assert view |> element("#card-drawer-description-input") |> render() =~ "Current text"
    end

    test "the drawer aside is wide on desktop and full width on mobile", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer aside.drawer-panel.w-full")
      assert render(view) =~ "lg:w-[min(760px,94vw)]"
    end

    test "the drawer body has a main column beside a properties rail", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer-main #card-drawer-conversation")
      assert has_element?(view, "#card-drawer-main #card-drawer-activity")
      assert has_element?(view, "#card-drawer-rail.lg\\:border-l")
    end

    test "editing the description opens a tall textarea", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view |> element("#card-drawer-description-display") |> render_click()

      assert has_element?(view, "#card-drawer-description-input[rows='12']")
    end

    test "the title editor carries the InlineEdit hook wired to its cancel button", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view |> element("#card-drawer-title-display") |> render_click()

      # The hook consumes Escape (cancel + stopPropagation) so it never reaches
      # the drawer's phx-window-keydown="close_drawer".
      assert has_element?(view, ~s(#card-drawer-title-input[phx-hook="InlineEdit"]))
      assert has_element?(view, ~s(#card-drawer-title-input[data-cancel-id="card-drawer-title-cancel"]))
      assert has_element?(view, "#card-drawer-title-cancel")
      # The window-level close binding is still present for a not-editing Escape.
      assert has_element?(view, "[phx-window-keydown='close_drawer']")
    end

    test "the composer textareas submit on ⌘/Ctrl+Enter via the SubmitOnCmdEnter hook", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, ~s(#card-drawer-comment-input[phx-hook="SubmitOnCmdEnter"]))
    end

    test "Archive removes the card from the board, closes the drawer, and flashes", %{
      conn: conn,
      user: user
    } do
      board = Boards.get_or_create_default_board(user)
      [backlog | _rest] = board.stages
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      html = view |> element("#archive-card-button") |> render_click()

      assert_patch(view, ~p"/board/#{board.slug}")
      refute has_element?(view, "#card-drawer")
      refute has_element?(view, "#stage-col-1-cards .board-card", "Draft the spec")
      # the stage's only card was just archived, so it auto-collapses to its
      # strip (MMF 12c) — the count still reads 0 there.
      assert has_element?(view, "#stage-strip-#{backlog.id} .stage-count", "0")
      assert html =~ "Card archived."
      assert board |> Cards.list_archived_cards() |> Enum.map(& &1.title) == ["Draft the spec"]
    end

    test "opening an archived card by URL shows the banner + Restore, hides edit actions, and logs the phrase",
         %{conn: conn, user: user, card: card} do
      {:ok, _archived} = Cards.archive_card(card, {:user, user.id})
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-archived-banner")
      assert has_element?(view, "#restore-card-button")
      refute has_element?(view, "#archive-card-button")
      refute has_element?(view, "#card-drawer-status-form")

      assert has_element?(
               view,
               "#card-drawer-activity .timeline-activity-phrase",
               "archived this card"
             )
    end

    test "Restore from the drawer banner returns the card to the board", %{
      conn: conn,
      user: user,
      card: card
    } do
      {:ok, _archived} = Cards.archive_card(card)
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view |> element("#restore-card-button") |> render_click()

      assert has_element?(view, "#stage-col-1-cards .board-card", "Draft the spec")
      refute has_element?(view, "#card-archived-banner")
      assert Cards.get_card_by_ref(board, "RLY-1").archived_at == nil
    end
  end

  describe "archived cards modal" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog | _rest] = board.stages
      {:ok, keep} = Cards.create_card(backlog, %{title: "Stay on board"})
      {:ok, gone} = Cards.create_card(backlog, %{title: "Archived one"})
      {:ok, _gone} = Cards.archive_card(gone)
      %{board: board, backlog: backlog, keep: keep}
    end

    test "the header button shows the archived count", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#archived-cards-button", "1")
    end

    test "opening the modal lists the archived card with its stage and a Restore button",
         %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view |> element("#archived-cards-button") |> render_click()

      assert has_element?(view, "#archived-modal")
      assert has_element?(view, "#archived-list", "Archived one")
      assert has_element?(view, "#archived-list", "RLY-2")
      assert has_element?(view, "#archived-list", "Backlog")
      assert has_element?(view, "#archived-restore-#{archived_id(board)}")
      refute has_element?(view, "#archived-list", "Stay on board")
    end

    test "Restore from the modal returns the card to the board and drops the count",
         %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      view |> element("#archived-cards-button") |> render_click()

      view |> element("#archived-restore-#{archived_id(board)}") |> render_click()

      assert has_element?(view, "#stage-col-1-cards .board-card", "Archived one")
      assert has_element?(view, "#archived-cards-button", "0")
      assert Cards.count_archived_cards(board) == 0
    end

    test "clicking a row opens that card's drawer and closes the modal",
         %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      view |> element("#archived-cards-button") |> render_click()

      view |> element("#open-archived-card-#{archived_id(board)}") |> render_click()

      assert_patch(view, ~p"/board/#{board.slug}?card=RLY-2")
      assert has_element?(view, "#card-drawer")
      assert has_element?(view, "#card-archived-banner")
      refute has_element?(view, "#archived-modal")
    end
  end

  describe "drawer plan and branch" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog | _rest] = board.stages
      {:ok, card} = Cards.create_card(backlog, %{title: "Wire the runner"})
      %{board: board, backlog: backlog, card: card}
    end

    test "a card with a plan renders the Plan section collapsed by default",
         %{conn: conn, card: card, user: user} do
      {:ok, _card} = Cards.update_card(card, %{plan: "## Task 1\n\n- [ ] do the thing"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "details#card-plan .collapse-title", "Plan")
      # plan renders as markdown-turned-HTML (heading + list item), not raw text
      assert has_element?(view, "details#card-plan #card-plan-body.md h2", "Task 1")
      assert has_element?(view, "details#card-plan #card-plan-body li", "do the thing")
      # collapsed by default: the <details> must NOT carry the open attribute
      refute has_element?(view, "details#card-plan[open]")
    end

    test "a card with a branch renders the branch chip in the rail",
         %{conn: conn, card: card, user: user} do
      {:ok, _card} = Cards.update_card(card, %{branch: "rly-21-card-branch-plan"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer-rail #card-branch", "rly-21-card-branch-plan")
      assert has_element?(view, "#card-branch.font-mono")
    end

    test "a card with neither branch nor plan renders neither", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer")
      refute has_element?(view, "#card-plan")
      refute has_element?(view, "#card-branch")
    end

    test "a card with a pr_url renders the PR link in the rail",
         %{conn: conn, card: card, user: user} do
      {:ok, _card} = Cards.update_card(card, %{pr_url: "https://github.com/acme/relay/pull/42"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer-rail #card-pr[href='https://github.com/acme/relay/pull/42']")
    end

    test "a card with no pr_url renders no PR link", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer")
      refute has_element?(view, "#card-pr")
    end
  end

  describe "drawer move menu" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
      spec = Enum.find(board.stages, &(&1.name == "Spec"))
      plan = Enum.find(board.stages, &(&1.name == "Plan"))
      {:ok, card} = Cards.create_card(backlog, %{title: "Pass the baton"})
      %{board: board, backlog: backlog, spec: spec, plan: plan, card: card}
    end

    test "lists every stage except the card's current one",
         %{conn: conn, backlog: backlog, spec: spec, plan: plan, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer-move")
      refute has_element?(view, "#card-drawer-move-to-#{backlog.id}")
      assert has_element?(view, "#card-drawer-move-to-#{spec.id}", "Spec")
      assert has_element?(view, "#card-drawer-move-to-#{plan.id}", "Plan")
    end

    test "labels a sub-lane target with the parent's name, not the raw composite Stage.name",
         %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, review} = Boards.enable_lane(code, :review)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer-move-to-#{review.id}", "Code · Review")
      refute has_element?(view, "#card-drawer-move-to-#{review.id}", "Code:Review")
    end

    test "a card sitting in a sub-lane shows the human label in the drawer chip and rail, not the raw composite Stage.name",
         %{conn: conn, board: board, card: card} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, review} = Boards.enable_lane(code, :review)
      {:ok, _moved} = Cards.move_card(card, review, 0)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer .drawer-stage-chip", "Code · Review")
      assert has_element?(view, "#card-drawer-rail", "Code · Review")
      refute has_element?(view, "#card-drawer", "Code:Review")
    end

    test "moving from the drawer persists like a drag and appends to the bottom",
         %{conn: conn, backlog: backlog, spec: spec, card: card, user: user} do
      {:ok, existing} = Cards.create_card(spec, %{title: "Already in Spec"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view |> element("#card-drawer-move-to-#{spec.id}") |> render_click()

      moved = Repo.get!(Card, card.id)
      assert moved.stage_id == spec.id
      assert moved.position == 2
      assert Repo.get!(Card, existing.id).position == 1

      assert has_element?(view, "#stage-col-#{spec.position}-cards .board-card", "Pass the baton")
      refute has_element?(view, "#stage-col-1-cards .board-card")
      assert has_element?(view, "#stage-strip-#{backlog.id} .stage-count", "0")
      assert has_element?(view, "#stage-col-#{spec.position} .stage-count", "2")
    end

    test "the drawer stage chip and menu update after the move", %{conn: conn, plan: plan, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view |> element("#card-drawer-move-to-#{plan.id}") |> render_click()

      assert has_element?(view, "#card-drawer .drawer-stage-chip.badge-secondary", "Plan")
      refute has_element?(view, "#card-drawer-move-to-#{plan.id}")
    end
  end

  describe "drawer baton rail" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog | _rest] = board.stages
      {:ok, card} = Cards.create_card(backlog, %{title: "Baton"})
      %{board: board, backlog: backlog, card: card}
    end

    test "an unowned card shows None for active worker and owners, with both add controls",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      refute has_element?(view, "#card-drawer-rail .rail-owner[data-active='true']")
      assert has_element?(view, "#card-drawer-rail .rail-owners", "None")
      assert has_element?(view, "#card-drawer-assign-ai")
      assert has_element?(view, "#card-drawer-add-me")
    end

    test "Add me makes the current user the active worker and reflects on the board card",
         %{conn: conn, user: user, card: card} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view |> element("#card-drawer-add-me") |> render_click()

      assert has_element?(
               view,
               "#card-drawer-rail .rail-owner[data-actor-type='user'][data-active='true']",
               "Test User"
             )

      refute has_element?(view, "#card-drawer-add-me")

      assert [owner] = Repo.all(CardOwner)
      assert owner.card_id == card.id
      assert owner.user_id == user.id

      assert has_element?(view, "#stage-col-1-cards .board-card[data-active-owner='human']")
    end

    test "Assign AI makes Relay AI the sole owner: Take over shows, add controls hide",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view |> element("#card-drawer-add-me") |> render_click()
      view |> element("#card-drawer-assign-ai") |> render_click()

      assert has_element?(
               view,
               "#card-drawer-rail .rail-owner[data-actor-type='agent'][data-active='true']",
               "Relay AI"
             )

      # exclusivity: the human owner is gone; no paused badge remains
      refute has_element?(view, "#card-drawer-rail .rail-owner[data-actor-type='user']")
      refute has_element?(view, "#card-drawer-rail .rail-owner-paused")

      # Take over is the affordance next to Relay AI; Add me / Assign AI are hidden
      assert has_element?(view, "#card-drawer-take-over")
      refute has_element?(view, "#card-drawer-add-me")
      refute has_element?(view, "#card-drawer-assign-ai")

      assert has_element?(view, "#stage-col-1-cards .board-card[data-active-owner='ai']")
    end

    test "Take over flips ownership to the current user and leaves status untouched",
         %{conn: conn, user: user, card: card} do
      {:ok, _card} = Cards.set_status(card, %{"status" => "working"})
      {:ok, _card} = Cards.add_owner(card, :agent)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer-take-over")
      view |> element("#card-drawer-take-over") |> render_click()

      assert has_element?(
               view,
               "#card-drawer-rail .rail-owner[data-actor-type='user'][data-active='true']",
               "Test User"
             )

      assert has_element?(view, "#card-drawer-rail .rail-owner[data-actor-type='user']", "Test User")
      refute has_element?(view, "#card-drawer-rail .rail-owner[data-actor-type='agent']")
      refute has_element?(view, "#card-drawer-take-over")

      reloaded = Cards.get_card_by_ref(board, "RLY-1")
      assert [%{actor_type: :user, user_id: uid}] = reloaded.owners
      assert uid == user.id
      assert reloaded.status == :working
    end

    test "an AI-owned card renders the Relay AI owner label", %{conn: conn, user: user, card: card} do
      {:ok, _card} = Cards.add_owner(card, :agent)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#card-drawer-rail .rail-owner[data-actor-type='agent']", "Relay AI")
    end

    test "removing the human owner leaves the card unowned", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view |> element("#card-drawer-add-me") |> render_click()
      view |> element("#card-drawer-remove-owner-user-#{user.id}") |> render_click()

      assert has_element?(view, "#card-drawer-rail .rail-owners", "None")
      refute has_element?(view, "#card-drawer-rail .rail-owner[data-active='true']")
      assert Repo.all(CardOwner) == []
      refute has_element?(view, "#stage-col-1-cards .board-card[data-active-owner]")
    end

    test "the rail shows a read-only status badge — no status select or progress input",
         %{conn: conn, card: card, user: user} do
      {:ok, _card} = Cards.set_status(card, %{"status" => "working"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      # read-only badge in the rail
      assert has_element?(view, "#card-drawer-rail .rail-status .status-badge", "working")

      # no editable status surface anywhere in the drawer
      refute has_element?(view, "#card-drawer-status-form")
      refute has_element?(view, "#card-drawer select[name='card[status]']")
      refute has_element?(view, "#card-drawer input[name='card[progress]']")
    end

    test "adding another user's id as owner is ignored", %{conn: conn, user: user} do
      other = insert(:user)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      render_click(view, "add_owner", %{"actor_type" => "user", "user_id" => other.id})

      assert Repo.all(CardOwner) == []
      assert has_element?(view, "#card-drawer-rail .rail-owners", "None")
    end
  end

  describe "board header rename" do
    setup :register_and_log_in_user

    setup %{user: user} do
      %{board: Boards.get_or_create_default_board(user)}
    end

    test "the header name is click-to-edit and opens an editor", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#board-title #board-name-display", board.name)
      refute has_element?(view, "#board-name-form")

      view |> element("#board-name-display") |> render_click()

      assert has_element?(view, "#board-name-form #board-name-input")
    end

    test "saving a new name persists it and returns to the read state", %{conn: conn, board: board, user: user} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view |> element("#board-name-display") |> render_click()
      view |> form("#board-name-form", board: %{name: "Launch board"}) |> render_submit()

      refute has_element?(view, "#board-name-form")
      assert has_element?(view, "#board-title #board-name-display", "Launch board")
      assert Boards.get_or_create_default_board(user).name == "Launch board"
    end

    test "a blank name is rejected inline and nothing changes", %{conn: conn, board: board, user: user} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view |> element("#board-name-display") |> render_click()
      html = view |> form("#board-name-form", board: %{name: ""}) |> render_submit()

      assert html =~ "should be at least 1 character"
      assert Boards.get_or_create_default_board(user).name == board.name
    end

    test "cancel restores the read state without saving", %{conn: conn, board: board, user: user} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view |> element("#board-name-display") |> render_click()
      view |> element("#board-name-cancel") |> render_click()

      refute has_element?(view, "#board-name-form")
      assert has_element?(view, "#board-name-display", board.name)
      assert Boards.get_or_create_default_board(user).name == board.name
    end

    test "renaming from the header never changes the slug", %{conn: conn, board: board, user: user} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view |> element("#board-name-display") |> render_click()
      view |> form("#board-name-form", board: %{name: "Renamed"}) |> render_submit()

      assert Boards.get_or_create_default_board(user).slug == board.slug
    end
  end

  describe "top bar" do
    test "shows the avatar image and a sign out link", %{conn: conn} do
      user = insert(:user, avatar_url: "https://example.com/me.png")
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/board/#{board.slug}")

      assert has_element?(view, "#user-avatar img")
      assert has_element?(view, "#sign-out")
    end

    test "falls back to initials when the user has no avatar image", %{conn: conn} do
      user = insert(:user, avatar_url: nil, name: "Ada Lovelace")
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/board/#{board.slug}")

      refute has_element?(view, "#user-avatar img")
      assert has_element?(view, "#user-avatar", "AL")
    end
  end

  describe "signing out" do
    test "after sign out, the board route requires signing in again", %{conn: conn} do
      user = insert(:user)
      conn = conn |> log_in_user(user) |> delete(~p"/logout")

      board = Boards.get_or_create_default_board(user)
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/board/#{board.slug}")
    end
  end

  describe "activity attribution" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog | _rest] = board.stages
      %{board: board, backlog: backlog}
    end

    test "creating a card via the composer logs :created attributed to the signed-in user",
         %{conn: conn, user: user, backlog: backlog} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      expand_stage(view, backlog)
      view |> element("#stage-col-1-new-card") |> render_click()

      view
      |> form("#stage-col-1-compose-form", card: %{title: "Attributed"})
      |> render_submit()

      assert [%Schemas.Activity{type: :created, actor_type: :user, user_id: user_id}] =
               Repo.all(Schemas.Activity)

      assert user_id == user.id
    end

    test "drawer actions (owners, move) log user-attributed entries",
         %{conn: conn, user: user, board: board, backlog: backlog} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Card"})
      # Review is a review-type stage; the freshly-created card is :queued, which
      # isn't valid there, so the move also triggers an implicit ADR 0003 status
      # snap to :in_review — exercised here alongside owners/move attribution.
      review = Enum.find(board.stages, &(&1.name == "Review"))

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view |> element("#card-drawer-add-me") |> render_click()
      view |> element("#card-drawer-move-to-#{review.id}") |> render_click()

      entries = Repo.all(from a in Schemas.Activity, where: a.card_id == ^card.id, order_by: a.id)

      assert Enum.map(entries, & &1.type) == [:created, :owners_changed, :moved, :status_changed]

      [_created | user_entries] = entries
      assert Enum.all?(user_entries, &(&1.actor_type == :user and &1.user_id == user.id))
    end
  end

  describe "card timeline" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
      plan = Enum.find(board.stages, &(&1.name == "Plan"))
      {:ok, card} = Cards.create_card(backlog, %{title: "Draft the spec"})
      %{board: board, backlog: backlog, plan: plan, card: card}
    end

    test "the drawer shows the agent-attributed created entry", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(
               view,
               "#card-drawer-activity .timeline-activity-phrase",
               "created this card"
             )
    end

    test "a card with no history shows the empty state", %{conn: conn, backlog: backlog, user: user} do
      insert(:card, stage: backlog, title: "Bare", ref_number: 500, position: 5)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-500")

      assert has_element?(view, "#card-drawer-activity", "No activity yet")
    end

    test "posting a comment persists it and appends it with author and timestamp",
         %{conn: conn, user: user, card: card} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view
      |> form("#card-drawer-comment-form", comment: %{body: "Looks good to me"})
      |> render_submit()

      assert [comment] = Repo.all(Comment)
      assert comment.card_id == card.id
      assert comment.actor_type == :user
      assert comment.user_id == user.id
      assert comment.body == "Looks good to me"

      assert has_element?(
               view,
               "#timeline-comment-#{comment.id} .timeline-comment-body",
               "Looks good to me"
             )

      assert has_element?(view, "#timeline-comment-#{comment.id} .timeline-author", user.name)

      assert has_element?(
               view,
               "#timeline-comment-#{comment.id} .timeline-time",
               Calendar.strftime(comment.inserted_at, "%b %d, %H:%M")
             )
    end

    test "a blank comment is rejected and persists nothing", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view
      |> form("#card-drawer-comment-form", comment: %{body: ""})
      |> render_submit()

      assert has_element?(view, "#card-drawer-comment-form", "can't be blank")
      assert Repo.aggregate(Comment, :count) == 0
    end

    test "an agent-authored comment renders with the Relay AI identity",
         %{conn: conn, card: card, user: user} do
      comment = insert(:comment, card: card, body: "Implemented — ready for review.")

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert has_element?(view, "#timeline-comment-#{comment.id} .timeline-author", "Relay AI")

      assert has_element?(
               view,
               "#timeline-comment-#{comment.id} .timeline-comment-body",
               "Implemented — ready for review."
             )
    end

    test "adding an owner in the open drawer appends the activity entry live",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view |> element("#card-drawer-add-me") |> render_click()

      assert has_element?(
               view,
               "#card-drawer-activity .timeline-activity-phrase",
               "added #{user.name} as owner"
             )
    end

    test "moving from the open drawer appends the moved entry live", %{conn: conn, plan: plan, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view |> element("#card-drawer-move-to-#{plan.id}") |> render_click()

      assert has_element?(
               view,
               "#card-drawer-activity .timeline-activity-phrase",
               "moved Backlog → Plan"
             )
    end

    test "the conversation lists comments oldest first", %{conn: conn, user: user, backlog: backlog} do
      card = insert(:card, stage: backlog, title: "History", ref_number: 501, position: 6)
      c1 = insert(:comment, card: card, user: user, body: "Kickoff", inserted_at: ~U[2026-07-01 09:00:00Z])
      c2 = insert(:comment, card: card, body: "Done", inserted_at: ~U[2026-07-03 09:00:00Z])

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-501")

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#card-drawer-conversation > li.timeline-entry[id]")
        |> LazyHTML.attribute("id")

      assert ids == ["timeline-comment-#{c1.id}", "timeline-comment-#{c2.id}"]
    end

    test "the activity log lists entries newest first", %{conn: conn, backlog: backlog, user: user} do
      card = insert(:card, stage: backlog, title: "Log", ref_number: 502, position: 7)
      a1 = insert(:activity, card: card, type: :created, inserted_at: ~U[2026-07-01 09:00:00Z])
      a2 = insert(:activity, card: card, type: :commented, inserted_at: ~U[2026-07-03 09:00:00Z])

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-502")

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#card-drawer-activity > li.activity-entry[id]")
        |> LazyHTML.attribute("id")

      assert ids == ["timeline-activity-#{a2.id}", "timeline-activity-#{a1.id}"]
    end
  end

  describe "sub-lanes" do
    setup %{conn: conn} do
      user = insert(:user)
      board = Boards.get_or_create_default_board(user)
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, _review} = Boards.enable_lane(code, :review)
      %{conn: Plug.Test.init_test_session(conn, user_id: user.id), board: board, code: code}
    end

    test "renders a stage's review sub-lane stacked with its own count", %{conn: conn, code: code, board: board} do
      insert(:card, stage: code, title: "Main work", position: 1, ref_number: 1)

      {:ok, _view, html} = live(conn, ~p"/board/#{board.slug}")
      review = code |> Boards.sublanes() |> hd()
      assert html =~ "sublane-#{review.id}"
      assert html =~ "Review"
    end

    test "a card moved into the review sub-lane renders there", %{conn: conn, code: code, board: board} do
      review = code |> Boards.sublanes() |> hd()
      card = insert(:card, stage: code)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      render_hook(view, "move_card", %{"ref" => card_ref(card), "stage_id" => review.id})

      # Assert by container + title (the card's DOM id is stream-generated, not #card-<id>).
      assert has_element?(view, "#sublane-#{review.id}-cards", card.title)
    end

    defp card_ref(card), do: "RLY-#{card.ref_number}"
  end

  describe "collapsed empty stages (MMF 12c)" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
      spec = Enum.find(board.stages, &(&1.name == "Spec"))
      %{board: board, backlog: backlog, spec: spec}
    end

    test "an empty stage renders the collapsed strip; a stage with a card renders the full column",
         %{conn: conn, backlog: backlog, spec: spec, user: user} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Keep me open"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      # non-empty Backlog: full column, no strip
      assert has_element?(view, "#stage-col-1-cards .board-card", "Keep me open")
      refute has_element?(view, "#stage-strip-#{backlog.id}")

      # empty Spec: strip with rotated name + count 0, no expanded column
      assert has_element?(view, "#stage-strip-#{spec.id}.stage-strip", "Spec")
      assert has_element?(view, "#stage-strip-#{spec.id} .stage-strip-name", "Spec")
      assert has_element?(view, "#stage-strip-#{spec.id} .stage-count", "0")
      refute has_element?(view, "#stage-col-#{spec.position}-cards")

      strip_html = view |> element("#stage-strip-#{spec.id}") |> render()
      assert strip_html =~ "width:44px"
      assert strip_html =~ "writing-mode:vertical-rl"
      assert strip_html =~ "border:1px dashed oklch(0.90 0.006 255)"
    end

    test "the strip is a DnD drop zone carrying its stage id", %{conn: conn, spec: spec, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-strip-#{spec.id}.stage-cards[data-stage-id='#{spec.id}']")
    end

    test "clicking a strip force-opens the empty stage for the session",
         %{conn: conn, backlog: backlog, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      expand_stage(view, backlog)

      refute has_element?(view, "#stage-strip-#{backlog.id}")
      assert has_element?(view, "#stage-col-1-cards .stage-empty", "No cards yet")

      # it stays expanded on subsequent renders, even while still empty
      assert render(view) =~ "stage-col-1-cards"
    end

    test "moving the last card out collapses the stage",
         %{conn: conn, backlog: backlog, spec: spec, user: user} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Last one"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      refute has_element?(view, "#stage-strip-#{backlog.id}")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => 0})

      assert has_element?(view, "#stage-strip-#{backlog.id} .stage-count", "0")
      refute has_element?(view, "#stage-col-1-cards")
    end

    test "moving a card onto a collapsed strip expands it and the card renders there",
         %{conn: conn, backlog: backlog, spec: spec, user: user} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Incoming"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-strip-#{spec.id}")

      # exactly what board_dnd.js pushes on a drop over the strip (index 0 — empty zone)
      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => "#{spec.id}", "index" => 0})

      refute has_element?(view, "#stage-strip-#{spec.id}")
      assert has_element?(view, "#stage-col-#{spec.position}-cards .board-card", "Incoming")
      assert has_element?(view, "#stage-col-#{spec.position} .stage-count", "1")
    end

    test "a stage whose only card sits in a sub-lane does not collapse",
         %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, review} = Boards.enable_lane(code, :review)
      insert(:card, stage: review, title: "In review", position: 1, ref_number: 9)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      refute has_element?(view, "#stage-strip-#{code.id}")
      assert has_element?(view, "#sublane-#{review.id}-cards .board-card", "In review")
    end
  end

  describe "collapsed empty sub-lanes (MMF 12c)" do
    setup %{conn: conn} do
      user = insert(:user)
      board = Boards.get_or_create_default_board(user)
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, review} = Boards.enable_lane(code, :review)

      %{
        conn: Plug.Test.init_test_session(conn, user_id: user.id),
        board: board,
        code: code,
        review: review
      }
    end

    test "an empty review sub-lane renders its 34px strip inside the expanded stage",
         %{conn: conn, code: code, review: review, board: board} do
      insert(:card, stage: code, title: "Main work", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(
               view,
               "#sublane-#{review.id}-strip.sublane-strip.stage-cards[data-stage-id='#{review.id}']"
             )

      assert has_element?(view, "#sublane-#{review.id}-strip .sublane-strip-name", "Review")
      assert has_element?(view, "#sublane-#{review.id}-strip .sublane-strip-count", "0")
      refute has_element?(view, "#sublane-#{review.id}-cards")

      strip_html = view |> element("#sublane-#{review.id}-strip") |> render()
      assert strip_html =~ "flex:0 0 34px"
      assert strip_html =~ "writing-mode:vertical-rl"
      assert strip_html =~ "oklch(0.52 0.12 65)"
    end

    test "a sub-lane with a card renders expanded", %{conn: conn, review: review, board: board} do
      insert(:card, stage: review, title: "Please review", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#sublane-#{review.id}-cards .board-card", "Please review")
      refute has_element?(view, "#sublane-#{review.id}-strip")
    end

    test "moving a card onto the sub-lane strip expands it and the card renders there",
         %{conn: conn, code: code, review: review, board: board} do
      card = insert(:card, stage: code, title: "Ready for review", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#sublane-#{review.id}-strip")

      render_hook(view, "move_card", %{
        "ref" => "RLY-#{card.ref_number}",
        "stage_id" => review.id,
        "index" => 0
      })

      refute has_element?(view, "#sublane-#{review.id}-strip")
      assert has_element?(view, "#sublane-#{review.id}-cards .board-card", "Ready for review")
    end

    test "clicking the sub-lane strip force-opens the empty lane",
         %{conn: conn, code: code, review: review, board: board} do
      insert(:card, stage: code, title: "Main work", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view |> element("#sublane-#{review.id}-strip") |> render_click()

      refute has_element?(view, "#sublane-#{review.id}-strip")
      assert has_element?(view, "#sublane-#{review.id}-cards .stage-empty", "Empty")
    end
  end

  defp expand_stage(view, stage) do
    view |> element("#stage-strip-#{stage.id}") |> render_click()
  end

  defp stage_titles(view, position) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#stage-col-#{position}-cards .board-card .card-title")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  # Byte offset of `needle` in `html`, for asserting DOM element ordering.
  defp index_of(html, needle) do
    {pos, _len} = :binary.match(html, needle)
    pos
  end

  defp archived_id(board), do: board |> Cards.list_archived_cards() |> hd() |> Map.fetch!(:id)
end
