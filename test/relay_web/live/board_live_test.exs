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
        |> Enum.map(&String.trim(LazyHTML.text(&1)))

      assert names == ["Backlog", "Spec", "Plan", "Code", "Review", "Deploy", "Done"]
    end

    test "groups the stages under their category bands in order", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog, spec, plan, code, review, deploy, done] = board.stages

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#category-unstarted h2.category-band", "Unstarted")
      assert has_element?(view, "#category-planning h2.category-band", "Planning")
      assert has_element?(view, "#category-in_progress h2.category-band", "In progress")
      assert has_element?(view, "#category-complete h2.category-band", "Complete")

      # a fresh board is empty, so every stage renders as its collapsed strip
      assert has_element?(view, "#category-unstarted #stage-strip-#{backlog.id}", "Backlog")
      assert has_element?(view, "#category-unstarted #stage-strip-#{spec.id}", "Spec")
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

      {:ok, view, _html} = live(conn, ~p"/board")

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

    test "shows the right Human/AI owner swatch on each stage", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/board")

      for stage <- board.stages do
        assert has_element?(
                 view,
                 ~s(#stage-strip-#{stage.id} .stage-owner-swatch[data-owner="#{stage.owner}"])
               )
      end
    end

    test "a fresh board collapses every empty stage to a strip", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      document = view |> render() |> LazyHTML.from_fragment()

      assert document |> LazyHTML.query("#board .stage-strip") |> Enum.count() == 7
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

    test "a stage's compose CTA reveals the composer for that stage only", %{conn: conn, backlog: backlog} do
      {:ok, view, _html} = live(conn, ~p"/board")

      expand_stage(view, backlog)

      refute has_element?(view, "#stage-col-1-compose-form")

      view |> element("#stage-col-1-new-card") |> render_click()

      assert has_element?(view, "#stage-col-1-compose-form")
      refute has_element?(view, "#stage-col-2-compose-form")
    end

    test "submitting the composer creates a card in that stage and clears the input",
         %{conn: conn, backlog: backlog} do
      {:ok, view, _html} = live(conn, ~p"/board")

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

    test "creating cards assigns per-board incrementing refs shown on the cards", %{conn: conn, backlog: backlog} do
      {:ok, view, _html} = live(conn, ~p"/board")

      expand_stage(view, backlog)
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
         %{conn: conn, backlog: backlog, board: board} do
      [_backlog, spec | _rest] = board.stages
      insert(:card, stage: backlog, title: "Only here", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#stage-col-1-cards .board-card", "Only here")
      refute has_element?(view, "#stage-col-2-cards .board-card")
      assert has_element?(view, "#stage-strip-#{spec.id} .stage-count", "0")
    end

    test "cancel closes the composer without creating a card", %{conn: conn, backlog: backlog} do
      {:ok, view, _html} = live(conn, ~p"/board")

      expand_stage(view, backlog)
      view |> element("#stage-col-1-new-card") |> render_click()
      view |> element("#stage-col-1-composer button", "Cancel") |> render_click()

      refute has_element?(view, "#stage-col-1-compose-form")
      assert Repo.all(Card) == []
    end

    test "submitting a blank title keeps the composer open and creates nothing", %{conn: conn, backlog: backlog} do
      {:ok, view, _html} = live(conn, ~p"/board")

      expand_stage(view, backlog)
      view |> element("#stage-col-1-new-card") |> render_click()
      view |> form("#stage-col-1-compose-form", card: %{title: ""}) |> render_submit()

      assert has_element?(view, "#stage-col-1-compose-form")
      assert Repo.all(Card) == []
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

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#stage-col-1 .stage-count", "2")

      for stage <- tl(board.stages) do
        assert has_element?(view, "#stage-strip-#{stage.id} .stage-count", "0")
      end
    end

    test "creating a card bumps its stage's count", %{conn: conn, board: board, backlog: backlog} do
      [_backlog, spec | _rest] = board.stages

      {:ok, view, _html} = live(conn, ~p"/board")

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
      [backlog, spec, plan | _rest] = board.stages
      %{board: board, backlog: backlog, spec: spec, plan: plan}
    end

    test "a move_card event moves the card to the target stage and persists across reloads",
         %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Take the baton"})

      {:ok, view, _html} = live(conn, ~p"/board")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => 0})

      assert has_element?(view, "#stage-col-2-cards .board-card", "Take the baton")
      refute has_element?(view, "#stage-col-1-cards .board-card")
      assert Repo.get!(Card, card.id).stage_id == spec.id

      {:ok, reloaded, _html} = live(conn, ~p"/board")
      assert has_element?(reloaded, "#stage-col-2-cards .board-card", "Take the baton")
    end

    test "moving updates both lane counts", %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Mover"})

      {:ok, view, _html} = live(conn, ~p"/board")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => 0})

      assert has_element?(view, "#stage-strip-#{backlog.id} .stage-count", "0")
      assert has_element?(view, "#stage-col-2 .stage-count", "1")
    end

    test "reordering within a stage persists the new order across reloads",
         %{conn: conn, backlog: backlog} do
      {:ok, _first} = Cards.create_card(backlog, %{title: "First"})
      {:ok, _second} = Cards.create_card(backlog, %{title: "Second"})
      {:ok, _third} = Cards.create_card(backlog, %{title: "Third"})

      {:ok, view, _html} = live(conn, ~p"/board")

      render_hook(view, "move_card", %{"ref" => "RLY-3", "stage_id" => backlog.id, "index" => 0})

      assert stage_titles(view, 1) == ["Third", "First", "Second"]

      {:ok, reloaded, _html} = live(conn, ~p"/board")
      assert stage_titles(reloaded, 1) == ["Third", "First", "Second"]
    end

    test "accepts string stage_id and index (phx-value parity)",
         %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Stringly"})

      {:ok, view, _html} = live(conn, ~p"/board")

      render_hook(view, "move_card", %{
        "ref" => "RLY-1",
        "stage_id" => Integer.to_string(spec.id),
        "index" => "0"
      })

      assert Repo.get!(Card, card.id).stage_id == spec.id
    end

    test "omitting index appends the card to the bottom of the target stage",
         %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Mover"})
      {:ok, existing} = Cards.create_card(spec, %{title: "Already there"})

      {:ok, view, _html} = live(conn, ~p"/board")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id})

      assert Repo.get!(Card, card.id).position == 2
      assert Repo.get!(Card, existing.id).position == 1
      assert stage_titles(view, 2) == ["Already there", "Mover"]
    end

    test "a ref that is not on this board is rejected", %{conn: conn, spec: spec} do
      other_stage = insert(:stage)
      theirs = insert(:card, stage: other_stage, title: "Theirs", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => 0})

      assert Repo.get!(Card, theirs.id).stage_id == other_stage.id
      refute has_element?(view, "#stage-col-2-cards .board-card")
    end

    test "a target stage that is not on this board is rejected",
         %{conn: conn, backlog: backlog} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Stay home"})
      other_stage = insert(:stage)

      {:ok, view, _html} = live(conn, ~p"/board")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => other_stage.id, "index" => 0})

      assert Repo.get!(Card, card.id).stage_id == backlog.id
      assert has_element?(view, "#stage-col-1-cards .board-card", "Stay home")
    end

    test "garbage stage_id or index is ignored", %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Unmoved"})

      {:ok, view, _html} = live(conn, ~p"/board")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => "banana", "index" => 0})
      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => "banana"})

      assert Repo.get!(Card, card.id).stage_id == backlog.id
      assert has_element?(view, "#stage-col-1-cards .board-card", "Unmoved")
    end

    test "moving the drawer-selected card refreshes the drawer's stage chip",
         %{conn: conn, backlog: backlog, plan: plan} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Chip check"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

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

    test "the board mounts the BoardDnD hook", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#board[phx-hook='BoardDnD']")
    end

    test "cards are draggable and carry their ref", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#stage-col-1-cards .board-card[draggable='true'][data-ref='RLY-1']")
    end

    test "every stage's card container is a drop zone carrying its stage id",
         %{conn: conn, backlog: backlog} do
      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#stage-col-1-cards.stage-cards[data-stage-id='#{backlog.id}']")

      zones =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#board .stage-cards[data-stage-id]")
        |> Enum.count()

      assert zones == 7
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

    test "an unowned card renders neutral: transparent accent, no owners, no mismatch", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#stage-col-1-cards .board-card.border-l-transparent", "Baton card")
      refute has_element?(view, "#stage-col-1-cards .board-card .card-owners")
      refute has_element?(view, "#stage-col-1-cards .board-card .card-status")
      refute has_element?(view, "#stage-col-1-cards .board-card .card-mismatch")
    end

    test "an unowned card in an AI stage shows no mismatch", %{conn: conn, plan: plan} do
      {:ok, _card} = Cards.create_card(plan, %{title: "Unowned in Plan"})

      {:ok, view, _html} = live(conn, ~p"/board")

      refute has_element?(view, "#stage-col-3-cards .board-card .card-mismatch")
    end

    test "a human-owned card renders blue with a human owner avatar",
         %{conn: conn, user: user, card: card} do
      {:ok, _card} = Cards.add_owner(card, {:user, user.id})

      {:ok, view, _html} = live(conn, ~p"/board")

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

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(
               view,
               "#stage-col-3-cards .board-card[data-active-owner='ai'].border-l-secondary"
             )

      assert has_element?(
               view,
               ~s(#stage-col-3-cards .board-card .card-owners [data-actor-type="agent"])
             )
    end

    test "a needs_input card shows the amber NEEDS INPUT box", %{conn: conn, card: card} do
      {:ok, _card} = Cards.set_status(card, %{"status" => "needs_input"})

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(
               view,
               "#stage-col-1-cards .board-card.border-l-warning .card-needs-input",
               "NEEDS INPUT"
             )
    end

    test "a working card shows its progress in the status line", %{conn: conn, card: card} do
      {:ok, _card} = Cards.set_status(card, %{"status" => "working", "progress" => "61"})

      {:ok, view, _html} = live(conn, ~p"/board")

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

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(
               view,
               "#stage-col-3-cards .board-card.border-l-error .card-mismatch",
               "meant to be used by agents"
             )
    end

    test "an AI-active card in a human stage shows the red meant-for-humans warning",
         %{conn: conn, card: card} do
      {:ok, _card} = Cards.add_owner(card, :agent)

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(
               view,
               "#stage-col-1-cards .board-card.border-l-error .card-mismatch",
               "meant for humans"
             )
    end

    test "moving a card changes neither its owners nor its status",
         %{conn: conn, board: board, user: user, card: card, plan: plan} do
      {:ok, _card} = Cards.add_owner(card, {:user, user.id})

      {:ok, view, _html} = live(conn, ~p"/board")

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

    test "no drawer renders without a card param", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      refute has_element?(view, "#card-drawer")
    end

    test "clicking a board card patches to its ref and opens the drawer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      view |> element("#stage-col-1-cards .board-card") |> render_click()

      assert_patch(view, ~p"/board?card=RLY-1")
      assert has_element?(view, "#card-drawer")
      assert has_element?(view, "#card-drawer-title-display", "Draft the spec")
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

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      # each long-form field is markdown turned into HTML, not literal text
      assert has_element?(view, "#card-drawer-description-view h2", "Desc head")
      assert has_element?(view, "#card-drawer-description-view strong", "descbold")
      assert has_element?(view, "#card-drawer-spec-view strong", "specbold")
      assert has_element?(view, "#card-plan-body strong", "planbold")
      assert has_element?(view, ".timeline-comment-body strong", "commentbold")
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

    test "the title shows as read-only text until clicked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer-title-display", "Draft the spec")
      refute has_element?(view, "#card-drawer-title-form")
    end

    test "clicking the title opens the inline editor", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-title-display") |> render_click()

      assert has_element?(view, "#card-drawer-title-form textarea#card-drawer-title-input")
    end

    test "saving the title persists and reflects on drawer and board card",
         %{conn: conn, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-title-display") |> render_click()
      view |> form("#card-drawer-title-form", card: %{title: "Sharper title"}) |> render_submit()

      assert Repo.get!(Card, card.id).title == "Sharper title"
      assert has_element?(view, "#card-drawer-title-display", "Sharper title")
      refute has_element?(view, "#card-drawer-title-form")
      assert has_element?(view, "#stage-col-1-cards .board-card .card-title", "Sharper title")
      refute has_element?(view, "#stage-col-1-cards .board-card .card-title", "Draft the spec")
    end

    test "a blank title is rejected with an error and nothing changes", %{conn: conn, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-title-display") |> render_click()
      view |> form("#card-drawer-title-form", card: %{title: ""}) |> render_submit()

      assert has_element?(view, "#card-drawer-title-form", "can't be blank")
      assert Repo.get!(Card, card.id).title == "Draft the spec"
    end

    test "a long title wraps in the header rather than scrolling one line",
         %{conn: conn, card: card} do
      {:ok, _} = Cards.update_card(card, %{title: String.duplicate("verylongword ", 15)})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer-title-display.whitespace-pre-wrap.break-words")
    end

    test "pressing Escape closes the open drawer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer")

      view |> element("#card-drawer") |> render_keydown(%{"key" => "Escape"})

      assert_patch(view, ~p"/board")
      refute has_element?(view, "#card-drawer")
    end

    test "no window-keydown close binding exists when no card is open", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      refute has_element?(view, "#card-drawer")
      refute has_element?(view, "[phx-window-keydown='close_drawer']")
    end

    test "clicking the description area opens the textarea editor", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer-description-edit", "Add a description")
      refute has_element?(view, "#card-drawer-description-form")

      view |> element("#card-drawer-description-edit") |> render_click()

      assert has_element?(
               view,
               "#card-drawer-description-form textarea#card-drawer-description-input"
             )
    end

    test "saving the description persists and renders it as markdown",
         %{conn: conn, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-description-edit") |> render_click()

      view
      |> form("#card-drawer-description-form", card: %{description: "Line one\n\nLine two"})
      |> render_submit()

      refute has_element?(view, "#card-drawer-description-form")
      # a blank line is markdown for two paragraphs, rendered as HTML
      assert has_element?(view, "#card-drawer-description-view.md p", "Line one")
      assert has_element?(view, "#card-drawer-description-view.md p", "Line two")
      assert Repo.get!(Card, card.id).description == "Line one\n\nLine two"
    end

    test "cancel closes the editor without saving", %{conn: conn, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-description-edit") |> render_click()
      view |> element("#card-drawer-description-cancel") |> render_click()

      refute has_element?(view, "#card-drawer-description-form")
      assert has_element?(view, "#card-drawer-description-edit", "Add a description")
      assert Repo.get!(Card, card.id).description == nil
    end

    test "a saved description survives a fresh deep-link visit", %{conn: conn, card: card} do
      {:ok, _card} = Cards.update_card(card, %{description: "Persisted\ntext"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer-description-view")
      assert view |> element("#card-drawer-description-view") |> render() =~ "Persisted\ntext"
    end

    test "editing pre-fills the textarea with the current description", %{conn: conn, card: card} do
      {:ok, _card} = Cards.update_card(card, %{description: "Current text"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")
      view |> element("#card-drawer-description-edit") |> render_click()

      assert view |> element("#card-drawer-description-input") |> render() =~ "Current text"
    end

    test "the drawer aside is wide on desktop and full width on mobile", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer aside.drawer-panel.w-full")
      assert render(view) =~ "lg:w-2/3"
    end

    test "the drawer body has a main column beside a properties rail", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer-main #card-drawer-conversation")
      assert has_element?(view, "#card-drawer-main #card-drawer-activity")
      assert has_element?(view, "#card-drawer-rail.lg\\:border-l")
    end

    test "editing the description opens a tall textarea", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-description-edit") |> render_click()

      assert has_element?(view, "#card-drawer-description-input[rows='12']")
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
         %{conn: conn, card: card} do
      {:ok, _card} = Cards.update_card(card, %{plan: "## Task 1\n\n- [ ] do the thing"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "details#card-plan .collapse-title", "Plan")
      # plan renders as markdown-turned-HTML (heading + list item), not raw text
      assert has_element?(view, "details#card-plan #card-plan-body.md h2", "Task 1")
      assert has_element?(view, "details#card-plan #card-plan-body li", "do the thing")
      # collapsed by default: the <details> must NOT carry the open attribute
      refute has_element?(view, "details#card-plan[open]")
    end

    test "a card with a branch renders the branch chip in the rail",
         %{conn: conn, card: card} do
      {:ok, _card} = Cards.update_card(card, %{branch: "rly-21-card-branch-plan"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer-rail #card-branch", "rly-21-card-branch-plan")
      assert has_element?(view, "#card-branch.font-mono")
    end

    test "a card with neither branch nor plan renders neither", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer")
      refute has_element?(view, "#card-plan")
      refute has_element?(view, "#card-branch")
    end

    test "a card with a pr_url renders the PR link in the rail",
         %{conn: conn, card: card} do
      {:ok, _card} = Cards.update_card(card, %{pr_url: "https://github.com/acme/relay/pull/42"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer-rail #card-pr[href='https://github.com/acme/relay/pull/42']")
    end

    test "a card with no pr_url renders no PR link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer")
      refute has_element?(view, "#card-pr")
    end
  end

  describe "drawer move menu" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog, spec, plan | _rest] = board.stages
      {:ok, card} = Cards.create_card(backlog, %{title: "Pass the baton"})
      %{board: board, backlog: backlog, spec: spec, plan: plan, card: card}
    end

    test "lists every stage except the card's current one",
         %{conn: conn, backlog: backlog, spec: spec, plan: plan} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer-move")
      refute has_element?(view, "#card-drawer-move-to-#{backlog.id}")
      assert has_element?(view, "#card-drawer-move-to-#{spec.id}", "Spec")
      assert has_element?(view, "#card-drawer-move-to-#{plan.id}", "Plan")
    end

    test "labels a sub-lane target with the parent's name, not the raw composite Stage.name",
         %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, review} = Boards.enable_lane(code, :review)

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer-move-to-#{review.id}", "Code · Review")
      refute has_element?(view, "#card-drawer-move-to-#{review.id}", "Code:Review")
    end

    test "a card sitting in a sub-lane shows the human label in the drawer chip and rail, not the raw composite Stage.name",
         %{conn: conn, board: board, card: card} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, review} = Boards.enable_lane(code, :review)
      {:ok, _moved} = Cards.move_card(card, review, 0)

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer .drawer-stage-chip", "Code · Review")
      assert has_element?(view, "#card-drawer-rail", "Code · Review")
      refute has_element?(view, "#card-drawer", "Code:Review")
    end

    test "moving from the drawer persists like a drag and appends to the bottom",
         %{conn: conn, backlog: backlog, spec: spec, card: card} do
      {:ok, existing} = Cards.create_card(spec, %{title: "Already in Spec"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-move-to-#{spec.id}") |> render_click()

      moved = Repo.get!(Card, card.id)
      assert moved.stage_id == spec.id
      assert moved.position == 2
      assert Repo.get!(Card, existing.id).position == 1

      assert has_element?(view, "#stage-col-2-cards .board-card", "Pass the baton")
      refute has_element?(view, "#stage-col-1-cards .board-card")
      assert has_element?(view, "#stage-strip-#{backlog.id} .stage-count", "0")
      assert has_element?(view, "#stage-col-2 .stage-count", "2")
    end

    test "the drawer stage chip and menu update after the move", %{conn: conn, plan: plan} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

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
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer-rail .rail-active-worker", "None")
      assert has_element?(view, "#card-drawer-rail .rail-owners", "None")
      assert has_element?(view, "#card-drawer-assign-ai")
      assert has_element?(view, "#card-drawer-add-me")
    end

    test "Add me makes the current user the active worker and reflects on the board card",
         %{conn: conn, user: user, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-add-me") |> render_click()

      assert has_element?(
               view,
               "#card-drawer-rail .rail-active-worker .owner-pill.badge-primary",
               "Human"
             )

      assert has_element?(view, "#card-drawer-rail .rail-active-worker", "Test User")

      assert has_element?(
               view,
               "#card-drawer-rail .rail-owner[data-actor-type='user']",
               "Test User"
             )

      refute has_element?(view, "#card-drawer-add-me")

      assert [owner] = Repo.all(CardOwner)
      assert owner.card_id == card.id
      assert owner.user_id == user.id

      assert has_element?(view, "#stage-col-1-cards .board-card[data-active-owner='human']")
    end

    test "Assign AI flips the active worker to AI and pauses the human", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-add-me") |> render_click()
      view |> element("#card-drawer-assign-ai") |> render_click()

      assert has_element?(
               view,
               "#card-drawer-rail .rail-active-worker .owner-pill.badge-secondary",
               "AI"
             )

      assert has_element?(
               view,
               "#card-drawer-rail .rail-owner[data-actor-type='user'] .rail-owner-paused",
               "paused"
             )

      refute has_element?(view, "#card-drawer-assign-ai")
      assert has_element?(view, "#stage-col-1-cards .board-card[data-active-owner='ai']")
    end

    test "releasing the AI returns the baton to the human", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-add-me") |> render_click()
      view |> element("#card-drawer-assign-ai") |> render_click()
      view |> element("#card-drawer-remove-owner-agent") |> render_click()

      assert has_element?(
               view,
               "#card-drawer-rail .rail-active-worker .owner-pill.badge-primary",
               "Human"
             )

      refute has_element?(view, "#card-drawer-rail .rail-owner[data-actor-type='agent']")
      assert has_element?(view, "#card-drawer-assign-ai")
      refute has_element?(view, "#card-drawer-rail .rail-owner-paused")
    end

    test "removing the human owner leaves the card unowned", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-add-me") |> render_click()
      view |> element("#card-drawer-remove-owner-user-#{user.id}") |> render_click()

      assert has_element?(view, "#card-drawer-rail .rail-active-worker", "None")
      assert Repo.all(CardOwner) == []
      refute has_element?(view, "#stage-col-1-cards .board-card[data-active-owner]")
    end

    test "setting status from the drawer persists and updates the board card",
         %{conn: conn, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> form("#card-drawer-status-form", card: %{status: "needs_input"}) |> render_change()

      assert Repo.get!(Card, card.id).status == :needs_input

      assert has_element?(
               view,
               "#stage-col-1-cards .board-card .card-needs-input",
               "NEEDS INPUT"
             )
    end

    test "working reveals the progress input; progress shows on the board badge",
         %{conn: conn, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      refute has_element?(view, "#card-drawer-status-form input[name='card[progress]']")

      view |> form("#card-drawer-status-form", card: %{status: "working"}) |> render_change()

      assert has_element?(view, "#card-drawer-status-form input[name='card[progress]']")

      view
      |> form("#card-drawer-status-form", card: %{status: "working", progress: "61"})
      |> render_change()

      assert Repo.get!(Card, card.id).progress == 61

      assert has_element?(
               view,
               "#stage-col-1-cards .board-card .card-status[data-status='working']",
               "working · 61%"
             )
    end

    test "an invalid status payload changes nothing", %{conn: conn, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view
      |> element("#card-drawer-status-form")
      |> render_change(%{"card" => %{"status" => "banana"}})

      assert Repo.get!(Card, card.id).status == :queued
    end

    test "adding another user's id as owner is ignored", %{conn: conn} do
      other = insert(:user)

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      render_click(view, "add_owner", %{"actor_type" => "user", "user_id" => other.id})

      assert Repo.all(CardOwner) == []
      assert has_element?(view, "#card-drawer-rail .rail-active-worker", "None")
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

  describe "activity attribution" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog | _rest] = board.stages
      %{board: board, backlog: backlog}
    end

    test "creating a card via the composer logs :created attributed to the signed-in user",
         %{conn: conn, user: user, backlog: backlog} do
      {:ok, view, _html} = live(conn, ~p"/board")

      expand_stage(view, backlog)
      view |> element("#stage-col-1-new-card") |> render_click()

      view
      |> form("#stage-col-1-compose-form", card: %{title: "Attributed"})
      |> render_submit()

      assert [%Schemas.Activity{type: :created, actor_type: :user, user_id: user_id}] =
               Repo.all(Schemas.Activity)

      assert user_id == user.id
    end

    test "drawer actions (status, owners, move) log user-attributed entries",
         %{conn: conn, user: user, board: board, backlog: backlog} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Card"})
      [_backlog, spec | _rest] = board.stages

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view
      |> form("#card-drawer-status-form", card: %{status: "in_review"})
      |> render_change()

      view |> element("#card-drawer-add-me") |> render_click()
      view |> element("#card-drawer-move-to-#{spec.id}") |> render_click()

      entries = Repo.all(from a in Schemas.Activity, where: a.card_id == ^card.id, order_by: a.id)

      assert Enum.map(entries, & &1.type) == [:created, :status_changed, :owners_changed, :moved]

      [_created | user_entries] = entries
      assert Enum.all?(user_entries, &(&1.actor_type == :user and &1.user_id == user.id))
    end
  end

  describe "card timeline" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog, _spec, plan | _rest] = board.stages
      {:ok, card} = Cards.create_card(backlog, %{title: "Draft the spec"})
      %{board: board, backlog: backlog, plan: plan, card: card}
    end

    test "the drawer shows the agent-attributed created entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(
               view,
               "#card-drawer-activity .timeline-activity-phrase",
               "created this card"
             )
    end

    test "a card with no history shows the empty state", %{conn: conn, backlog: backlog} do
      insert(:card, stage: backlog, title: "Bare", ref_number: 500, position: 5)

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-500")

      assert has_element?(view, "#card-drawer-activity", "No activity yet")
    end

    test "posting a comment persists it and appends it with author and timestamp",
         %{conn: conn, user: user, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

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

    test "a blank comment is rejected and persists nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view
      |> form("#card-drawer-comment-form", comment: %{body: ""})
      |> render_submit()

      assert has_element?(view, "#card-drawer-comment-form", "can't be blank")
      assert Repo.aggregate(Comment, :count) == 0
    end

    test "an agent-authored comment renders with the Relay AI identity",
         %{conn: conn, card: card} do
      comment = insert(:comment, card: card, body: "Implemented — ready for review.")

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#timeline-comment-#{comment.id} .timeline-author", "Relay AI")

      assert has_element?(
               view,
               "#timeline-comment-#{comment.id} .timeline-comment-body",
               "Implemented — ready for review."
             )
    end

    test "changing status in the open drawer appends the activity entry live", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view
      |> form("#card-drawer-status-form", card: %{status: "in_review"})
      |> render_change()

      assert has_element?(
               view,
               "#card-drawer-activity .timeline-activity-phrase",
               "set status to in_review"
             )
    end

    test "adding an owner in the open drawer appends the activity entry live",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-add-me") |> render_click()

      assert has_element?(
               view,
               "#card-drawer-activity .timeline-activity-phrase",
               "added #{user.name} as owner"
             )
    end

    test "moving from the open drawer appends the moved entry live", %{conn: conn, plan: plan} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

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

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-501")

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#card-drawer-conversation > li.timeline-entry[id]")
        |> LazyHTML.attribute("id")

      assert ids == ["timeline-comment-#{c1.id}", "timeline-comment-#{c2.id}"]
    end

    test "the activity log lists entries newest first", %{conn: conn, backlog: backlog} do
      card = insert(:card, stage: backlog, title: "Log", ref_number: 502, position: 7)
      a1 = insert(:activity, card: card, type: :created, inserted_at: ~U[2026-07-01 09:00:00Z])
      a2 = insert(:activity, card: card, type: :commented, inserted_at: ~U[2026-07-03 09:00:00Z])

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-502")

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

    test "renders a stage's review sub-lane stacked with its own count", %{conn: conn, code: code} do
      insert(:card, stage: code, title: "Main work", position: 1, ref_number: 1)

      {:ok, _view, html} = live(conn, ~p"/board")
      review = code |> Boards.sublanes() |> hd()
      assert html =~ "sublane-#{review.id}"
      assert html =~ "Review"
    end

    test "a card moved into the review sub-lane renders there", %{conn: conn, code: code} do
      review = code |> Boards.sublanes() |> hd()
      card = insert(:card, stage: code)

      {:ok, view, _html} = live(conn, ~p"/board")

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
      [backlog, spec | _rest] = board.stages
      %{board: board, backlog: backlog, spec: spec}
    end

    test "an empty stage renders the collapsed strip; a stage with a card renders the full column",
         %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Keep me open"})

      {:ok, view, _html} = live(conn, ~p"/board")

      # non-empty Backlog: full column, no strip
      assert has_element?(view, "#stage-col-1-cards .board-card", "Keep me open")
      refute has_element?(view, "#stage-strip-#{backlog.id}")

      # empty Spec: strip with rotated name + count 0, no expanded column
      assert has_element?(view, "#stage-strip-#{spec.id}.stage-strip", "Spec")
      assert has_element?(view, "#stage-strip-#{spec.id} .stage-strip-name", "Spec")
      assert has_element?(view, "#stage-strip-#{spec.id} .stage-count", "0")
      refute has_element?(view, "#stage-col-2-cards")

      strip_html = view |> element("#stage-strip-#{spec.id}") |> render()
      assert strip_html =~ "width:44px"
      assert strip_html =~ "writing-mode:vertical-rl"
      assert strip_html =~ "border:1px dashed oklch(0.90 0.006 255)"
    end

    test "the strip is a DnD drop zone carrying its stage id", %{conn: conn, spec: spec} do
      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#stage-strip-#{spec.id}.stage-cards[data-stage-id='#{spec.id}']")
    end

    test "clicking a strip force-opens the empty stage for the session",
         %{conn: conn, backlog: backlog} do
      {:ok, view, _html} = live(conn, ~p"/board")

      expand_stage(view, backlog)

      refute has_element?(view, "#stage-strip-#{backlog.id}")
      assert has_element?(view, "#stage-col-1-cards .stage-empty", "No cards yet")

      # it stays expanded on subsequent renders, even while still empty
      assert render(view) =~ "stage-col-1-cards"
    end

    test "moving the last card out collapses the stage",
         %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Last one"})

      {:ok, view, _html} = live(conn, ~p"/board")

      refute has_element?(view, "#stage-strip-#{backlog.id}")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => 0})

      assert has_element?(view, "#stage-strip-#{backlog.id} .stage-count", "0")
      refute has_element?(view, "#stage-col-1-cards")
    end

    test "moving a card onto a collapsed strip expands it and the card renders there",
         %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Incoming"})

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#stage-strip-#{spec.id}")

      # exactly what board_dnd.js pushes on a drop over the strip (index 0 — empty zone)
      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => "#{spec.id}", "index" => 0})

      refute has_element?(view, "#stage-strip-#{spec.id}")
      assert has_element?(view, "#stage-col-2-cards .board-card", "Incoming")
      assert has_element?(view, "#stage-col-2 .stage-count", "1")
    end

    test "a stage whose only card sits in a sub-lane does not collapse",
         %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, review} = Boards.enable_lane(code, :review)
      insert(:card, stage: review, title: "In review", position: 1, ref_number: 9)

      {:ok, view, _html} = live(conn, ~p"/board")

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
         %{conn: conn, code: code, review: review} do
      insert(:card, stage: code, title: "Main work", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board")

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

    test "a sub-lane with a card renders expanded", %{conn: conn, review: review} do
      insert(:card, stage: review, title: "Please review", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#sublane-#{review.id}-cards .board-card", "Please review")
      refute has_element?(view, "#sublane-#{review.id}-strip")
    end

    test "moving a card onto the sub-lane strip expands it and the card renders there",
         %{conn: conn, code: code, review: review} do
      card = insert(:card, stage: code, title: "Ready for review", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board")

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
         %{conn: conn, code: code, review: review} do
      insert(:card, stage: code, title: "Main work", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board")

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
end
