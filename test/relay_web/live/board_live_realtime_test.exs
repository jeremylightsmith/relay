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

    test "a card created in session A appears in session B with the count bumped", %{conn: conn} do
      {:ok, view_a, _html} = live(conn, ~p"/board")
      {:ok, view_b, _html} = live(conn, ~p"/board")

      view_a |> element("#stage-col-1-new-card") |> render_click()
      view_a |> form("#stage-col-1-compose-form", card: %{title: "Broadcast me"}) |> render_submit()

      assert has_element?(view_b, "#stage-col-1-cards .board-card", "Broadcast me")
      assert has_element?(view_b, "#stage-col-1 .stage-count", "1")
    end

    test "a move in session A restreams source and target in session B",
         %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Pass the baton"})

      {:ok, view_a, _html} = live(conn, ~p"/board")
      {:ok, view_b, _html} = live(conn, ~p"/board")

      render_hook(view_a, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => 0})

      assert has_element?(view_b, "#stage-col-2-cards .board-card", "Pass the baton")
      refute has_element?(view_b, "#stage-col-1-cards .board-card")
      assert has_element?(view_b, "#stage-col-1 .stage-count", "0")
      assert has_element?(view_b, "#stage-col-2 .stage-count", "1")
    end

    test "a status change in session A's drawer re-renders the board card in session B",
         %{conn: conn, backlog: backlog} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Needs a human"})

      {:ok, view_a, _html} = live(conn, ~p"/board?card=RLY-1")
      {:ok, view_b, _html} = live(conn, ~p"/board")

      view_a |> form("#card-drawer-status-form", card: %{status: "needs_input"}) |> render_change()

      assert has_element?(view_b, "#stage-col-1-cards .board-card .card-needs-input", "NEEDS INPUT")
    end

    test "a status change made elsewhere refreshes another session's open drawer",
         %{conn: conn, backlog: backlog} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Drawer sync"})

      {:ok, view_b, _html} = live(conn, ~p"/board?card=RLY-1")

      {:ok, _card} = Cards.set_status(card, %{"status" => "in_review"})

      assert has_element?(
               view_b,
               "#card-drawer-timeline .timeline-activity-phrase",
               "set status to in_review"
             )
    end

    test "an owner added elsewhere shows in another session's open drawer rail and board card",
         %{conn: conn, backlog: backlog} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Baton"})

      {:ok, view_b, _html} = live(conn, ~p"/board?card=RLY-1")

      {:ok, _card} = Cards.add_owner(card, :agent)

      assert has_element?(view_b, "#card-drawer-rail .rail-owner[data-actor-type='agent']")
      assert has_element?(view_b, "#stage-col-1-cards .board-card[data-active-owner='ai']")
    end

    test "a comment posted in session A appends to session B's open drawer timeline exactly once",
         %{conn: conn, backlog: backlog} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Chatty"})

      {:ok, view_a, _html} = live(conn, ~p"/board?card=RLY-1")
      {:ok, view_b, _html} = live(conn, ~p"/board?card=RLY-1")

      view_a |> form("#card-drawer-comment-form", comment: %{body: "Live comment"}) |> render_submit()

      comment = Repo.get_by!(Schemas.Comment, body: "Live comment")

      assert has_element?(view_b, "#timeline-comment-#{comment.id} .timeline-comment-body", "Live comment")
      # the acting session receives its own echo — applied idempotently
      assert element_count(view_a, "#timeline-comment-#{comment.id}") == 1
    end

    test "a comment does not touch a session whose drawer shows a different card",
         %{conn: conn, backlog: backlog} do
      {:ok, card_one} = Cards.create_card(backlog, %{title: "One"})
      {:ok, _card_two} = Cards.create_card(backlog, %{title: "Two"})

      {:ok, view_b, _html} = live(conn, ~p"/board?card=RLY-2")

      {:ok, comment} = Activity.add_comment(card_one, %{actor: :agent, body: "For card one"})

      refute has_element?(view_b, "#timeline-comment-#{comment.id}")
    end

    test "enabling and disabling a lane restructures another open session", %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))

      {:ok, view_b, _html} = live(conn, ~p"/board")

      {:ok, review} = Boards.enable_lane(code, :review)
      assert has_element?(view_b, "#sublane-#{review.id}-cards")

      {:ok, :disabled} = Boards.disable_lane(code, :review)
      refute has_element?(view_b, "#sublane-#{review.id}-cards")
    end
  end

  describe "board scoping" do
    setup :register_and_log_in_user

    test "a mutation on board A does not touch a session on board B", %{user: user} do
      board_a = Boards.get_or_create_default_board(user)
      [backlog_a | _rest] = board_a.stages

      other_user = insert(:user)
      _board_b = Boards.get_or_create_default_board(other_user)

      {:ok, view_b, _html} = live(log_in_user(build_conn(), other_user), ~p"/board")

      {:ok, _card} = Cards.create_card(backlog_a, %{title: "Only on A"})

      refute has_element?(view_b, ".board-card")
      assert has_element?(view_b, "#stage-col-1 .stage-count", "0")
    end
  end

  describe "idempotent event application" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog, spec | _rest] = board.stages
      %{board: board, backlog: backlog, spec: spec}
    end

    test "applying the same card_upserted twice leaves a single card", %{conn: conn, backlog: backlog} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Once"})

      {:ok, view, _html} = live(conn, ~p"/board")

      send(view.pid, {:card_upserted, card})
      send(view.pid, {:card_upserted, card})

      assert element_count(view, "#stage-col-1-cards .board-card") == 1
      assert has_element?(view, "#stage-col-1 .stage-count", "1")
    end

    test "applying the same card_moved twice leaves a single card in the target",
         %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Mover"})

      {:ok, view, _html} = live(conn, ~p"/board")

      {:ok, moved} = Cards.move_card(card, spec, 0)

      send(view.pid, {:card_moved, moved, backlog.id})
      send(view.pid, {:card_moved, moved, backlog.id})

      assert element_count(view, "#stage-col-1-cards .board-card") == 0
      assert element_count(view, "#stage-col-2-cards .board-card") == 1
      assert has_element?(view, "#stage-col-2 .stage-count", "1")
    end

    test "applying the same timeline_appended twice appends a single entry",
         %{conn: conn, backlog: backlog} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Talky"})
      {:ok, comment} = Activity.add_comment(card, %{actor: :agent, body: "Once only"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

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

    test "an API move updates an open board live", %{conn: conn, backlog: backlog, spec: spec, token: token} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Agent moves me"})

      {:ok, view, _html} = live(conn, ~p"/board")

      assert token |> api_conn() |> post(~p"/api/cards/RLY-1/move", %{stage: spec.id}) |> json_response(200)

      assert has_element?(view, "#stage-col-2-cards .board-card", "Agent moves me")
      refute has_element?(view, "#stage-col-1-cards .board-card")
      assert has_element?(view, "#stage-col-2 .stage-count", "1")
    end

    test "an API status change updates an open board live", %{conn: conn, backlog: backlog, token: token} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Agent works"})

      {:ok, view, _html} = live(conn, ~p"/board")

      assert token |> api_conn() |> patch(~p"/api/cards/RLY-1", %{status: "needs_input"}) |> json_response(200)

      assert has_element?(view, "#stage-col-1-cards .board-card .card-needs-input", "NEEDS INPUT")
    end

    test "an API comment appends to an open drawer's timeline", %{conn: conn, backlog: backlog, token: token} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Ping"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert token
             |> api_conn()
             |> post(~p"/api/cards/RLY-1/comments", %{body: "From the agent"})
             |> json_response(201)

      comment = Repo.get_by!(Schemas.Comment, card_id: card.id)
      assert has_element?(view, "#timeline-comment-#{comment.id} .timeline-comment-body", "From the agent")
      assert has_element?(view, "#timeline-comment-#{comment.id} .timeline-author", "Relay AI")
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
