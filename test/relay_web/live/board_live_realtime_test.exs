defmodule RelayWeb.BoardLiveRealtimeTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Repo

  describe "two sessions on the same board" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog, spec | _rest] = board.stages
      %{board: board, backlog: backlog, spec: spec}
    end

    test "a card created in session A appears in session B with the count bumped",
         %{conn: conn, backlog: backlog, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view_a, _html} = live(conn, ~p"/board/#{board.slug}")
      {:ok, view_b, _html} = live(conn, ~p"/board/#{board.slug}")

      view_a |> element("#stage-strip-#{backlog.id}") |> render_click()
      view_a |> element("#stage-col-1-new-card") |> render_click()
      view_a |> form("#stage-col-1-compose-form", card: %{title: "Broadcast me"}) |> render_submit()

      assert has_element?(view_b, "#stage-col-1-cards .board-card", "Broadcast me")
      assert has_element?(view_b, "#stage-col-1 .stage-count", "1")
    end

    test "a move in session A restreams source and target in session B",
         %{conn: conn, backlog: backlog, spec: spec, user: user} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Pass the baton"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view_a, _html} = live(conn, ~p"/board/#{board.slug}")
      {:ok, view_b, _html} = live(conn, ~p"/board/#{board.slug}")

      render_hook(view_a, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => 0})

      assert has_element?(view_b, "#stage-col-2-cards .board-card", "Pass the baton")
      refute has_element?(view_b, "#stage-col-1-cards .board-card")
      assert has_element?(view_b, "#stage-strip-#{backlog.id} .stage-count", "0")
      assert has_element?(view_b, "#stage-col-2 .stage-count", "1")
    end

    test "a status change in session A's drawer re-renders the board card in session B",
         %{conn: conn, board: board, user: user} do
      # A fresh card always arrives :ready (the schema default); flip it :in_review
      # so the drawer's review-approve button is live — approving moves it to Deploy
      # (:work, ai_enabled), snapping status to :working (RLY-48 default_status).
      review = Enum.find(board.stages, &(&1.name == "Review"))
      {:ok, card} = Cards.create_card(review, %{title: "Ready for review"})
      {:ok, _card} = Cards.set_status(card, %{"status" => "in_review"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view_a, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
      {:ok, view_b, _html} = live(conn, ~p"/board/#{board.slug}")

      view_a |> element("#review-approve") |> render_click()

      assert has_element?(view_b, ".board-card .card-status[data-status='working']")
    end

    test "a status change made elsewhere refreshes another session's open drawer",
         %{conn: conn, backlog: backlog, user: user} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Drawer sync"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view_b, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      {:ok, _card} = Cards.set_status(card, %{"status" => "in_review"})

      assert has_element?(
               view_b,
               "#card-drawer-activity .timeline-activity-phrase",
               "set status to in_review"
             )
    end

    test "an owner added elsewhere shows in another session's open drawer rail and board card",
         %{conn: conn, backlog: backlog, user: user} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Baton"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view_b, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      {:ok, _card} = Cards.add_owner(card, :agent)

      assert has_element?(view_b, "#card-drawer-rail .rail-owner[data-actor-type='agent']")
      assert has_element?(view_b, "#stage-col-1-cards .board-card[data-active-owner='ai']")
    end

    test "a comment posted in session A appends to session B's open drawer timeline exactly once",
         %{conn: conn, backlog: backlog, user: user} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Chatty"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view_a, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
      {:ok, view_b, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view_a |> form("#card-drawer-comment-form", comment: %{body: "Live comment"}) |> render_submit()

      comment = Repo.get_by!(Schemas.Comment, body: "Live comment")

      assert has_element?(view_b, "#timeline-comment-#{comment.id} .timeline-comment-body", "Live comment")
      # the acting session receives its own echo — applied idempotently
      assert element_count(view_a, "#timeline-comment-#{comment.id}") == 1
    end

    test "a comment does not touch a session whose drawer shows a different card",
         %{conn: conn, backlog: backlog, user: user} do
      {:ok, card_one} = Cards.create_card(backlog, %{title: "One"})
      {:ok, _card_two} = Cards.create_card(backlog, %{title: "Two"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view_b, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-2")

      {:ok, comment} = Activity.add_comment(card_one, %{actor: :agent, body: "For card one"})

      refute has_element?(view_b, "#timeline-comment-#{comment.id}")
    end

    test "enabling and disabling a lane restructures another open session", %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, _card} = Cards.create_card(code, %{title: "Keep Code expanded"})

      {:ok, view_b, _html} = live(conn, ~p"/board/#{board.slug}")

      {:ok, review} = Boards.enable_lane(code, :review)
      assert has_element?(view_b, "#sublane-#{review.id}-strip")

      {:ok, :disabled} = Boards.disable_lane(code, :review)
      refute has_element?(view_b, "#sublane-#{review.id}-strip")
    end

    test "emptying a stage in session A collapses it to a strip in session B",
         %{conn: conn, backlog: backlog, spec: spec, user: user} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Last one"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view_a, _html} = live(conn, ~p"/board/#{board.slug}")
      {:ok, view_b, _html} = live(conn, ~p"/board/#{board.slug}")

      refute has_element?(view_b, "#stage-strip-#{backlog.id}")

      render_hook(view_a, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => 0})

      assert has_element?(view_b, "#stage-strip-#{backlog.id} .stage-count", "0")
      assert has_element?(view_b, "#stage-col-2-cards .board-card", "Last one")
    end

    test "a board rename elsewhere retitles the board live in another session",
         %{conn: conn, board: board} do
      {:ok, view_b, _html} = live(conn, ~p"/board/#{board.slug}")

      {:ok, _board} = Boards.update_board(board, %{"name" => "Relayboard HQ"})

      assert view_b |> element("#board-title #board-name-input") |> render() =~ "Relayboard HQ"
    end

    test "a rename from the settings General pane retitles an open board session",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view_settings, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")
      {:ok, view_board, _html} = live(conn, ~p"/board/#{board.slug}")

      view_settings |> form("#board-name-form", board: %{name: "From settings"}) |> render_submit()

      assert view_board |> element("#board-title #board-name-input") |> render() =~ "From settings"
    end

    test "a card archived in session A disappears from session B and closes B's open drawer",
         %{conn: conn, backlog: backlog, user: user} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Archive me"})
      board = Boards.get_or_create_default_board(user)

      {:ok, view_a, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
      {:ok, view_b, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      view_a |> element("#archive-card-button") |> render_click()

      refute has_element?(view_b, "#stage-col-1-cards .board-card", "Archive me")
      # the stage's only card was just archived, so it auto-collapses to its
      # strip (MMF 12c) — the count still reads 0 there, for both sessions.
      assert has_element?(view_b, "#stage-strip-#{backlog.id} .stage-count", "0")
      refute has_element?(view_b, "#card-drawer")
    end
  end

  describe "board scoping" do
    setup :register_and_log_in_user

    test "a mutation on board A does not touch a session on board B", %{user: user} do
      board_a = Boards.get_or_create_default_board(user)
      [backlog_a | _rest] = board_a.stages

      other_user = insert(:user)
      board_b = Boards.get_or_create_default_board(other_user)
      [backlog_b | _rest] = board_b.stages

      {:ok, view_b, _html} = live(log_in_user(build_conn(), other_user), ~p"/board/#{board_b.slug}")

      {:ok, _card} = Cards.create_card(backlog_a, %{title: "Only on A"})

      refute has_element?(view_b, ".board-card")
      assert has_element?(view_b, "#stage-strip-#{backlog_b.id} .stage-count", "0")
    end
  end

  describe "idempotent event application" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog, spec | _rest] = board.stages
      %{board: board, backlog: backlog, spec: spec}
    end

    test "applying the same card_upserted twice leaves a single card", %{conn: conn, backlog: backlog, user: user} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Once"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      send(view.pid, {:card_upserted, card})
      send(view.pid, {:card_upserted, card})

      assert element_count(view, "#stage-col-1-cards .board-card") == 1
      assert has_element?(view, "#stage-col-1 .stage-count", "1")
    end

    test "applying the same card_moved twice leaves a single card in the target",
         %{conn: conn, backlog: backlog, spec: spec, user: user} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Mover"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      {:ok, moved} = Cards.move_card(card, spec, 0)

      send(view.pid, {:card_moved, moved, backlog.id})
      send(view.pid, {:card_moved, moved, backlog.id})

      assert element_count(view, "#stage-col-1-cards .board-card") == 0
      assert element_count(view, "#stage-col-2-cards .board-card") == 1
      assert has_element?(view, "#stage-col-2 .stage-count", "1")
    end

    test "applying the same timeline_appended twice appends a single entry",
         %{conn: conn, backlog: backlog, user: user} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Talky"})
      {:ok, comment} = Activity.add_comment(card, %{actor: :agent, body: "Once only"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      send(view.pid, {:timeline_appended, card.id, comment})
      send(view.pid, {:timeline_appended, card.id, comment})

      assert element_count(view, "#timeline-comment-#{comment.id}") == 1
    end
  end

  describe "API-driven changes update mounted LiveViews" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog, spec | _rest] = board.stages
      {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, user)
      %{board: board, backlog: backlog, spec: spec, token: token}
    end

    test "an API move updates an open board live", %{conn: conn, backlog: backlog, spec: spec, token: token, user: user} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Agent moves me"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert token |> api_conn() |> post(~p"/api/cards/RLY-1/move", %{stage: spec.id}) |> json_response(200)

      assert has_element?(view, "#stage-col-2-cards .board-card", "Agent moves me")
      refute has_element?(view, "#stage-col-1-cards .board-card")
      assert has_element?(view, "#stage-col-2 .stage-count", "1")
    end

    test "an API status change updates an open board live", %{conn: conn, backlog: backlog, token: token, user: user} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Agent works"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert token |> api_conn() |> patch(~p"/api/cards/RLY-1", %{status: "needs_input"}) |> json_response(200)

      assert has_element?(view, "#stage-col-1-cards .board-card .card-needs-input", "needs you")
    end

    test "an API comment appends to an open drawer's timeline", %{conn: conn, backlog: backlog, token: token, user: user} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Ping"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

      assert token
             |> api_conn()
             |> post(~p"/api/cards/RLY-1/comments", %{body: "From the agent"})
             |> json_response(201)

      comment = Repo.get_by!(Schemas.Comment, card_id: card.id)
      assert has_element?(view, "#timeline-comment-#{comment.id} .timeline-comment-body", "From the agent")
      assert has_element?(view, "#timeline-comment-#{comment.id} .timeline-author", "Relay AI")
    end

    test "an API branch/plan update refreshes another session's open drawer",
         %{conn: conn, backlog: backlog, token: token, user: user} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Runner card"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
      refute has_element?(view, "#card-plan-view")

      assert token
             |> api_conn()
             |> patch(~p"/api/cards/RLY-1", %{branch: "rly-9-live", plan: "Step 1: do it"})
             |> json_response(200)

      assert has_element?(view, "#card-drawer-rail #card-branch", "rly-9-live")
      assert has_element?(view, "#card-plan-view.md", "Step 1: do it")
    end
  end

  describe "stage configuration changes reflect on open boards (MMF 12)" do
    setup :register_and_log_in_user

    setup %{user: user} do
      %{board: Boards.get_or_create_default_board(user)}
    end

    test "a rename in one session's settings renders on another session's board",
         %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))

      {:ok, board_view, _html} = live(conn, ~p"/board/#{board.slug}")
      {:ok, settings_view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      settings_view |> element("#stage-#{code.id}-name-display") |> render_click()

      settings_view
      |> form("#stage-#{code.id}-name-form", stage: %{name: "Build"})
      |> render_submit()

      assert has_element?(board_view, "#stage-strip-#{code.id} h3", "Build")
    end

    test "an AI-enabled toggle re-tints the column and flips the card mismatch flag",
         %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, card} = Cards.create_card(code, %{title: "Agent task"})
      {:ok, _card} = Cards.add_owner(card, :agent)

      {:ok, board_view, _html} = live(conn, ~p"/board/#{board.slug}")
      {:ok, settings_view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      # ai_enabled stage + agent owner: no mismatch yet
      refute has_element?(board_view, "#stage-col-#{code.position} .card-mismatch")

      settings_view |> element("#stage-#{code.id}-ai-toggle") |> render_click()

      assert has_element?(
               board_view,
               "#stage-col-#{code.position} .stage-type-icon[data-type='work']"
             )

      assert has_element?(board_view, "#stage-col-#{code.position} .card-mismatch")
      # meant-for change only — the card's owner rows are untouched
      assert [%Schemas.CardOwner{actor_type: :agent}] = Repo.all(Schemas.CardOwner)
    end

    test "reordering swaps the columns and keeps card streams attached",
         %{conn: conn, board: board} do
      backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
      next_up = Enum.find(board.stages, &(&1.name == "Next up"))
      {:ok, _card} = Cards.create_card(backlog, %{title: "Ride along"})

      {:ok, board_view, _html} = live(conn, ~p"/board/#{board.slug}")
      {:ok, settings_view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      settings_view |> element("#stage-#{next_up.id}-up") |> render_click()

      assert has_element?(board_view, "#stage-strip-#{next_up.id} h3", "Next up")
      assert has_element?(board_view, "#stage-col-2 h3", "Backlog")
      assert has_element?(board_view, "#stage-col-2-cards .board-card", "Ride along")
    end

    test "reordering a stage across the Planning band updates the open board live",
         %{conn: conn, board: board} do
      spec = Enum.find(board.stages, &(&1.name == "Spec"))
      backlog = Enum.find(board.stages, &(&1.name == "Backlog"))

      {:ok, board_view, _html} = live(conn, ~p"/board/#{board.slug}")
      {:ok, settings_view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      settings_view |> element("#stage-#{spec.id}-down") |> render_click()

      assert has_element?(board_view, "#category-planning #stage-strip-#{spec.id}", "Spec")
      assert has_element?(board_view, "#category-unstarted #stage-strip-#{backlog.id}", "Backlog")
    end

    test "adding and deleting stages restructures the open board",
         %{conn: conn, board: board} do
      deploy = Enum.find(board.stages, &(&1.name == "Deploy"))

      {:ok, board_view, _html} = live(conn, ~p"/board/#{board.slug}")
      {:ok, settings_view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      settings_view |> element("#add-stage-unstarted") |> render_click()
      assert has_element?(board_view, "#category-unstarted h3", "New stage")

      settings_view |> element("#stage-#{deploy.id}-delete") |> render_click()
      refute render(board_view) =~ "Deploy"
    end
  end

  defp api_conn(token) do
    put_req_header(build_conn(), "authorization", "Bearer " <> token)
  end

  defp element_count(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.count()
  end
end
