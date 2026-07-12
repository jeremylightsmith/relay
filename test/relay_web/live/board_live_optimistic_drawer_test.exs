defmodule RelayWeb.BoardLiveOptimisticDrawerTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Events

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    [backlog | _rest] = board.stages
    {:ok, card} = Cards.create_card(backlog, %{title: "Optimistic open", tag: "perf"})

    {:ok, _} =
      Cards.update_card(card, %{
        description: "## Desc\n\n**descbold**",
        spec: "**specbold**",
        plan: "**planbold**"
      })

    %{board: board, backlog: backlog, card: card}
  end

  test "light data paints immediately with skeletons before the async fill",
       %{conn: conn, board: board} do
    # Assert against the join's own returned HTML snapshot (captured
    # synchronously before the async body-load task can possibly resolve),
    # not a fresh has_element?/2 render — otherwise this races the async
    # fill on a fast test DB.
    {:ok, view, html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

    # header/light data present without the heavy fetch
    assert html =~ "Optimistic open"
    assert html =~ "RLY-1"
    # heavy sections show skeletons, not content
    assert html =~ ~s(id="card-drawer-description-skeleton")
    assert html =~ ~s(id="card-drawer-spec-skeleton")
    assert html =~ ~s(id="card-plan-skeleton")
    refute html =~ ~s(id="card-drawer-description-view")

    # after the async fill, content is present and skeletons are gone
    render_async(view)

    assert has_element?(view, "#card-drawer-description-view strong", "descbold")
    assert has_element?(view, "#card-drawer-spec-view strong", "specbold")
    assert has_element?(view, "#card-plan-view strong", "planbold")
    refute has_element?(view, "#card-drawer-description-skeleton")
  end

  test "the async fill streams the timeline and conversation in",
       %{conn: conn, board: board, card: card, user: user} do
    {:ok, _comment} =
      Activity.add_comment(card, %{actor: {:user, user.id}, body: "**commentbold** note"})

    # Assert the loading spinner against the join's own returned HTML
    # snapshot (captured synchronously, before the async fill can resolve)
    # rather than a fresh has_element?/2 render, to avoid racing a fast
    # async fill.
    {:ok, view, html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    assert html =~ ~s(id="card-drawer-conversation-loading")

    render_async(view)

    assert has_element?(view, ".timeline-comment-body strong", "commentbold")
    refute has_element?(view, "#card-drawer-conversation-loading")
  end

  test "a cold deep-link renders light data + skeleton in the dead render, then fills",
       %{conn: conn, board: board} do
    # disconnected (dead) render: no async, skeleton shown, no crash
    conn = get(conn, ~p"/board/#{board.slug}?card=RLY-1")
    html = html_response(conn, 200)

    assert html =~ "Optimistic open"
    assert html =~ ~s(id="card-drawer-description-skeleton")
    refute html =~ "descbold"

    # the connected mount fills it in
    {:ok, view, _html} = live(conn)
    render_async(view)
    assert has_element?(view, "#card-drawer-description-view strong", "descbold")
  end

  test "opening B before A's fill resolves ends on B with A's body dropped",
       %{conn: conn, board: board, backlog: backlog} do
    {:ok, _b} = Cards.create_card(backlog, %{title: "Second card"})
    {:ok, _} = Cards.update_card(Cards.get_card_by_ref(board, "RLY-2"), %{description: "**bbody**"})

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    # switch to B before draining A's async
    render_patch(view, ~p"/board/#{board.slug}?card=RLY-2")
    render_async(view)

    assert has_element?(view, "#card-drawer-title-display", "Second card")
    assert has_element?(view, "#card-drawer-description-view strong", "bbody")
    # A's heavy body never overwrote B
    refute has_element?(view, "#card-drawer-description-view strong", "descbold")
  end

  test "handle_async exit clears the loading flag so the skeleton stops spinning" do
    socket = Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, :body_loading?, true)

    assert {:noreply, updated} =
             RelayWeb.BoardLive.handle_async(:load_card_body, {:exit, :boom}, socket)

    assert updated.assigns.body_loading? == false
  end

  test "a live refresh on the open card clears the skeleton with full content",
       %{conn: conn, board: board, card: card} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

    # a broadcast-style refresh carrying the full card must clear body_loading?
    {:ok, _} = Cards.update_card(card, %{plan: "**refreshedplan**"})
    Events.broadcast(board.id, {:card_upserted, Cards.get_card_by_ref(board, "RLY-1")})

    render_async(view)

    # both the refresh and the async fill leave the drawer non-skeleton + full
    assert has_element?(view, "#card-plan-view")
    refute has_element?(view, "#card-plan-skeleton")
  end
end
