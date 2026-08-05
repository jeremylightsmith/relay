defmodule RelayWeb.BoardLiveTalkTest do
  @moduledoc "RE268 — Talk is reachable three ways, streams, stops, and never hijacks typing."
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Cards
  alias Relay.FakeTalkExecutor
  alias Relay.Talk

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Relay.Boards.get_or_create_default_board(user)
    backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
    {:ok, card} = Cards.create_card(backlog, %{title: "Board search", description: "A search box."})
    %{board: board, card: card, ref: Cards.ref(board, card)}
  end

  defp open(conn, board, ref) do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
    render_async(view)
    view
  end

  test "the Talk tab and the header Talk button are on every card", ctx do
    view = open(ctx.conn, ctx.board, ctx.ref)

    assert has_element?(view, "#card-drawer-tab-talk")
    assert has_element?(view, "#card-drawer-talk-button")
    assert has_element?(view, "#card-drawer-tab-panel-talk.hidden")
  end

  # RE268 quality review — `drawer:block` beats `hidden` at >=45rem (equal specificity, later in
  # the stylesheet; see `lib/relay_web/live/boards_live.ex:69` for the same precedence used the
  # other way). Carrying BOTH classes on a non-Talk tab rendered the 548px terminal under every
  # tab on desktop. The panel must carry the desktop-visibility class ONLY while Talk is active.
  test "the Talk panel carries no drawer:block class while another tab is active", ctx do
    view = open(ctx.conn, ctx.board, ctx.ref)

    html = render(view)
    [panel_tag] = Regex.run(~r/<div id="card-drawer-tab-panel-talk"[^>]*>/, html)

    assert panel_tag =~ "hidden"
    refute panel_tag =~ "drawer:block"
  end

  test "clicking the tab reveals the terminal pane with the seed line", ctx do
    view = open(ctx.conn, ctx.board, ctx.ref)

    html = view |> element("#card-drawer-tab-talk") |> render_click()

    refute has_element?(view, "#card-drawer-tab-panel-talk.hidden")
    assert html =~ "relay talk #{ctx.ref}"
    assert html =~ "seeded with #{ctx.ref}"
  end

  test "the `t` shortcut opens Talk and is guarded against typing", ctx do
    view = open(ctx.conn, ctx.board, ctx.ref)

    render_keydown(element(view, "#card-drawer-tabs"), %{"key" => "t"})

    refute has_element?(view, "#card-drawer-tab-panel-talk.hidden")
    assert has_element?(view, ~s(#card-drawer-tabs[phx-hook="TypingKeyGuard"][data-guard-keys="t"]))
  end

  test "the seed line expands to one row per injected field", ctx do
    view = open(ctx.conn, ctx.board, ctx.ref)
    view |> element("#card-drawer-tab-talk") |> render_click()

    html = view |> element("#talk-pane-seed-toggle") |> render_click()

    assert html =~ "▾ seeded with #{ctx.ref}"
    assert html =~ "description"
    assert html =~ "A search box."
  end

  test "sending a turn posts it, shows Stop, and streams the answer in", ctx do
    executor = insert(:executor, board: ctx.board, name: "mac-1", capacity: %{"exclusive" => 1})
    view = open(ctx.conn, ctx.board, ctx.ref)
    view |> element("#card-drawer-tab-talk") |> render_click()

    html = view |> form("#talk-pane-composer", %{"text" => "why is this stuck?"}) |> render_submit()

    assert html =~ "why is this stuck?"
    assert has_element?(view, "#talk-pane-stop")

    turn = FakeTalkExecutor.claim(executor)
    FakeTalkExecutor.stream(turn, [{:tool, "Read · lib/relay.ex"}, {:out, "It is waiting on you."}])

    html = render(view)
    assert html =~ "Read · lib/relay.ex"
    assert html =~ "It is waiting on you."

    {:ok, _} = Talk.finish_turn(turn, :done, %{session_id: "s"})
    refute has_element?(view, "#talk-pane-stop")
  end

  test "Stop ends the turn and keeps the partial output", ctx do
    executor = insert(:executor, board: ctx.board, name: "mac-1", capacity: %{"exclusive" => 1})
    view = open(ctx.conn, ctx.board, ctx.ref)
    view |> element("#card-drawer-tab-talk") |> render_click()
    view |> form("#talk-pane-composer", %{"text" => "take your time"}) |> render_submit()

    turn = FakeTalkExecutor.claim(executor)
    FakeTalkExecutor.stream(turn, [{:out, "half an ans"}])

    view |> element("#talk-pane-stop") |> render_click()

    assert Talk.get_turn(turn.id).status == :stopped
    assert render(view) =~ "half an ans"
    refute has_element?(view, "#talk-pane-stop")
  end

  test "closing the drawer does not stop a turn — it finishes and its output is waiting", ctx do
    executor = insert(:executor, board: ctx.board, name: "mac-1", capacity: %{"exclusive" => 1})
    view = open(ctx.conn, ctx.board, ctx.ref)
    view |> element("#card-drawer-tab-talk") |> render_click()
    view |> form("#talk-pane-composer", %{"text" => "take your time"}) |> render_submit()

    # Detaching is not cancelling (ADR 0009 §1): only Stop stops. Navigating to the bare board
    # ends this LiveView process, which is the strongest form of "the drawer was closed".
    {:ok, _board_view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")
    turn = FakeTalkExecutor.claim(executor)
    FakeTalkExecutor.stream(turn, [{:out, "the whole answer"}])
    {:ok, done} = Talk.finish_turn(turn, :done, %{session_id: "s"})

    assert done.status == :done

    reopened = open(ctx.conn, ctx.board, ctx.ref)
    html = reopened |> element("#card-drawer-tab-talk") |> render_click()
    assert html =~ "the whole answer"
  end

  test "the scrollback survives closing and reopening the drawer", ctx do
    executor = insert(:executor, board: ctx.board, name: "mac-1", capacity: %{"exclusive" => 1})
    {:ok, _turn} = Talk.post_message(ctx.card, ctx.user, "first")
    FakeTalkExecutor.run(executor, [{:out, "an earlier answer"}])

    view = open(ctx.conn, ctx.board, ctx.ref)
    html = view |> element("#card-drawer-tab-talk") |> render_click()

    assert html =~ "first"
    assert html =~ "an earlier answer"
  end

  test "/clear hides the scrollback without deleting it", ctx do
    executor = insert(:executor, board: ctx.board, name: "mac-1", capacity: %{"exclusive" => 1})
    {:ok, _} = Talk.post_message(ctx.card, ctx.user, "first")
    FakeTalkExecutor.run(executor, [{:out, "an earlier answer"}])

    view = open(ctx.conn, ctx.board, ctx.ref)
    view |> element("#card-drawer-tab-talk") |> render_click()

    html = view |> form("#talk-pane-composer", %{"text" => "/clear"}) |> render_submit()

    refute html =~ "an earlier answer"
    assert Relay.Repo.aggregate(Schemas.TalkEvent, :count) > 0
  end

  test "talk output never reaches the card timeline", ctx do
    executor = insert(:executor, board: ctx.board, name: "mac-1", capacity: %{"exclusive" => 1})
    {:ok, _} = Talk.post_message(ctx.card, ctx.user, "first")
    FakeTalkExecutor.run(executor, [{:out, "an earlier answer"}])

    view = open(ctx.conn, ctx.board, ctx.ref)
    html = view |> element("#card-drawer-tab-activity") |> render_click()

    refute html =~ "an earlier answer"
  end

  test "an archived board offers no Talk writes", ctx do
    {:ok, _board} = Relay.Boards.archive_board(ctx.board)
    view = open(ctx.conn, ctx.board, ctx.ref)
    view |> element("#card-drawer-tab-talk") |> render_click()

    render_submit(view, "talk_send", %{"text" => "do something"})

    assert ctx.card |> Talk.session_for_card() |> Talk.active_turn() == nil
  end
end
