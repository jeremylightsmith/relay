defmodule RelayWeb.ValueStreamLiveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Relay.ValueStreamFixtures

  alias Relay.Cards

  setup :register_and_log_in_user

  setup %{user: user} do
    s = re_board()
    insert(:membership, board: s.board, user: user, email: user.email)
    code_flow(s.board)
    # recent enough that the 7d / 30d windows include it
    recent = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -2 * 86_400, :second)
    card = shipped_with_rework(s, recent)
    %{s: s, card: card, ref: Cards.ref(s.board, card), recent: recent, slug: s.board.slug}
  end

  # Next up@10 → Spec@100 → Spec · Review@160 → (approved) Spec · Done@200 → Plan@300 → Plan · Done@350
  # → Code@400 → Review@600 → (Request changes) Code@650 → Review@750 → (approved) Done@800.
  # One 100s :do execution in Code's first visit. Lead 790s: agent 100, human 140, nobody 550.
  defp shipped_with_rework(s, base) do
    card = card_in(s.done, base)
    walk(card, [{s.backlog, 0}, {s.next_up, 10}, {s.spec, 100}, {s.spec_review, 160}, {s.spec_done, 200}], base)
    decided(card, :approved, s.spec_review, s.spec_done, at(200, base))

    walk(
      card,
      [{s.spec_done, 200}, {s.plan, 300}, {s.plan_done, 350}, {s.code, 400}, {s.review, 600}, {s.code, 650}],
      base
    )

    decided(card, :rejected, s.review, s.code, at(650, base))
    walk(card, [{s.code, 650}, {s.review, 750}, {s.done, 800}], base)
    decided(card, :approved, s.review, s.done, at(800, base))
    executed(card, "implement", at(420, base), at(520, base), cost: Decimal.new("1.50"))
    card
  end

  defp texts(view, selector, within) do
    view
    |> element(within)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  describe "the single-card view" do
    test "opens from the drawer's Run tab on this card's stream, This card selected", ctx do
      {:ok, board_view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}?card=#{ctx.ref}")
      render_async(board_view)
      assert has_element?(board_view, "#card-value-stream-link[href='/board/#{ctx.slug}/value-stream?card=#{ctx.ref}']")

      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream?card=#{ctx.ref}")

      assert texts(view, ".vs-box-name", "#vs-map") ==
               ["Next up", "Spec", "Spec · Review", "Spec · Done", "Plan", "Plan · Done", "Code", "Review", "Done"]

      assert has_element?(view, "#vs-scope-card.btn-active")
      refute has_element?(view, "#vs-window")
      assert has_element?(view, "#vs-title", "The card stream — Next up → Done")
      assert has_element?(view, "#vs-subject", ctx.ref)
    end

    test "the tiles and the ladder's Δ reconcile with card_stream/1", ctx do
      stream = Relay.ValueStream.card_stream(ctx.card)
      assert stream.lead_secs == 790
      assert stream.baton_secs == %{agent: 100, human: 140, nobody: 550}

      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream?card=#{ctx.ref}")

      assert has_element?(view, "#vs-tile-lead-value", "13m")
      assert has_element?(view, "#vs-tile-efficiency-value", "12.7%")
      assert has_element?(view, "#vs-tile-nobody-value", "70%")
      assert has_element?(view, "#vs-tile-human-value", "18%")
      assert has_element?(view, "#vs-tile-agent-value", "13%")
      assert has_element?(view, "#vs-tile-cost-value", "$1.50")
      assert has_element?(view, "#vs-ladder-total", "Δ 13m")
      assert has_element?(view, "#vs-lead-bar-total", "13m")
      assert has_element?(view, "#vs-callout", "Read this before optimising a single node.")
      assert has_element?(view, "#vs-callout", "38%")
    end

    test "Request changes at Review draws an arc back to Code and a ×2 visits badge on Code", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream?card=#{ctx.ref}")

      assert has_element?(view, "#vs-arc-#{ctx.s.review.id}", "Request changes · 50% → re-runs Code")
      refute has_element?(view, "#vs-arc-#{ctx.s.spec_review.id}")
      assert has_element?(view, "#vs-box-#{ctx.s.code.id} .vs-visits", "×2")
      assert has_element?(view, "#vs-box-#{ctx.s.review.id}", "Rejected")
      assert has_element?(view, "#vs-box-#{ctx.s.done.id}", "Done")
    end

    test "flow boxes link to that flow's Flow Metrics for this card", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream?card=#{ctx.ref}")

      assert has_element?(view, "a#vs-box-#{ctx.s.code.id}[href='/board/#{ctx.slug}/flows/code/metrics?from=#{ctx.ref}']")
      refute has_element?(view, "a#vs-box-#{ctx.s.review.id}")
    end

    test "All cards keeps the card in the URL and shows the averaged view", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream?card=#{ctx.ref}")

      view |> element("#vs-scope-flow") |> render_click()
      assert_patch(view, ~p"/board/#{ctx.slug}/value-stream?card=#{ctx.ref}&scope=flow")
      assert has_element?(view, "#vs-window-last.btn-active")
      assert has_element?(view, "#vs-box-#{ctx.s.code.id}", "Mean work")
    end
  end

  describe "the board average" do
    test "is the third board view segment", ctx do
      {:ok, board_view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}")

      {:ok, view, _html} =
        board_view |> element("#board-view-tab-value-stream") |> render_click() |> follow_redirect(ctx.conn)

      assert has_element?(view, "#board-view-tab-value-stream[aria-current='page']")
      refute has_element?(view, "#vs-scope")
    end

    test "the window control patches the URL and Last 20 states the card count", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream")
      assert has_element?(view, "#vs-window-last.btn-active")
      assert has_element?(view, "#vs-tile-lead-sub", "mean of 1 done card")
      assert has_element?(view, "#vs-box-#{ctx.s.code.id}", "Mean work")
      assert has_element?(view, "#vs-box-#{ctx.s.review.id}", "Mean to decide")

      view |> element("#vs-window-30d") |> render_click()
      assert_patch(view, ~p"/board/#{ctx.slug}/value-stream?window=30d")
      assert has_element?(view, "#vs-window-30d.btn-active")
      assert has_element?(view, "#vs-subject", "done in the last 30d")

      view |> element("#vs-window-last") |> render_click()
      assert_patch(view, ~p"/board/#{ctx.slug}/value-stream")
      assert has_element?(view, "#vs-subject", "Mean of the last 1 done card")
    end

    test "a flow box lands on Flow Metrics for the same window", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream?window=7d")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#vs-box-#{ctx.s.code.id}") |> render_click()

      assert to == "/board/#{ctx.slug}/flows/code/metrics?window=7d"
    end

    test "a newly shipped card updates the view without a reload", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream")
      assert has_element?(view, "#vs-tile-lead-sub", "mean of 1 done card")

      second = shipped_with_rework(ctx.s, DateTime.add(ctx.recent, 3_600, :second))
      Relay.Events.broadcast(ctx.s.board.id, {:card_moved, second, ctx.s.review.id})

      assert render(view) =~ "mean of 2 done cards"

      # an event that changes no stage or decision is ignored without crashing
      send(view.pid, {:vote_changed, second.id})
      send(view.pid, {:timeline_appended, second.id, %Schemas.Activity{type: :approved}})
      assert render(view) =~ "mean of 2 done cards"
    end
  end

  describe "phones" do
    test "get the same map, scrolling sideways inside its container — no stacked list", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream?card=#{ctx.ref}")

      assert has_element?(view, "#vs-map[style*='overflow-x:auto']")
      refute has_element?(view, "#vs-map.hidden")
      refute has_element?(view, "#vs-list")
      assert has_element?(view, "#vs-tiles.grid-cols-2")
    end
  end

  describe "empty and unfinished states" do
    test "an unknown ref degrades to the averaged view", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream?card=RE999999")

      refute has_element?(view, "#vs-scope")
      assert has_element?(view, "#vs-window-last.btn-active")
      assert has_element?(view, "#vs-map")
    end

    test "a card that never entered the stream says so", ctx do
      backlog = card_in(ctx.s.backlog, ctx.recent)
      ref = Cards.ref(ctx.s.board, backlog)
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream?card=#{ref}")

      assert has_element?(view, "#vs-empty", "#{ref} hasn't entered the stream yet — it starts at Next up.")
    end

    test "an in-flight card renders to now: Done reads in progress, lead time is so far", ctx do
      working = card_in(ctx.s.code, ctx.recent, status: :working)
      walk(working, [{ctx.s.next_up, 0}, {ctx.s.code, 60}], ctx.recent)
      ref = Cards.ref(ctx.s.board, working)
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream?card=#{ref}")

      assert has_element?(view, "#vs-box-#{ctx.s.done.id}", "in progress")
      assert has_element?(view, "#vs-tile-lead", "SO FAR")
    end

    test "a window with no done cards says so", ctx do
      other = re_board()
      insert(:membership, board: other.board, user: ctx.user, email: ctx.user.email)
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{other.board.slug}/value-stream")

      assert has_element?(view, "#vs-empty", "No card has reached Done in this window yet.")
    end

    test "a board with no stages has no Done stage", ctx do
      bare = insert(:board)
      insert(:membership, board: bare, user: ctx.user, email: ctx.user.email)
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{bare.slug}/value-stream")

      assert has_element?(view, "#vs-empty", "This board has no Done stage.")
    end
  end
end
