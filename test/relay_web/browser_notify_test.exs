defmodule RelayWeb.BrowserNotifyTest do
  @moduledoc """
  RE399 — `RelayWeb.BrowserNotify` relays each `{:browser_notification, message}` on the signed-in
  user's `Relay.Push` topic to the client as `push_event "relay:notify"`, on every non-embedded
  authenticated LiveView, and navigates on `"browser_notify:open"`.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Push

  defp message(board) do
    %{
      id: "B1:needs_input:1",
      kind: "needs_input",
      title: "Question from the AI",
      body: "B1: x",
      card_ref: "B1",
      board_slug: board.slug,
      board_name: board.name,
      card_title: "x"
    }
  end

  defp broadcast(user, msg) do
    Phoenix.PubSub.broadcast(Relay.PubSub, Push.user_topic(user.id), {:browser_notification, msg})
  end

  defp backlog(board), do: Enum.find(board.stages, &(&1.name == "Backlog"))

  describe "on the authenticated session" do
    setup :register_and_log_in_user

    setup %{user: user} do
      %{board: Boards.get_or_create_default_board(user)}
    end

    test "relays a message on the user's topic to the client as relay:notify", %{
      conn: conn,
      user: user,
      board: board
    } do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      msg = message(board)
      broadcast(user, msg)

      assert_push_event(view, "relay:notify", ^msg)
    end

    test "every page listens, not just the board — a real status change reaches /boards", %{
      conn: conn,
      board: board
    } do
      other = insert(:user)
      insert(:membership, board: board, user: other, email: other.email)
      {:ok, card} = Cards.create_card(backlog(board), %{title: "Review me"})

      {:ok, view, _html} = live(conn, ~p"/boards")

      {:ok, _card} = Cards.set_status(card, %{status: :in_review}, :agent)

      assert_push_event(view, "relay:notify", %{kind: "in_review", title: "Ready for your review"})
    end

    test "an embedded board (?embed=1) never receives relay:notify and stays alive", %{
      conn: conn,
      user: user,
      board: board
    } do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

      broadcast(user, message(board))

      refute_push_event(view, "relay:notify", _)
      assert render(view)
    end

    test "card mode (/cards/:ref, embed forced in mount) never receives relay:notify", %{
      conn: conn,
      user: user,
      board: board
    } do
      {:ok, card} = Cards.create_card(backlog(board), %{title: "Native host"})
      ref = Cards.ref(board, card)

      {:ok, view, _html} = live(conn, ~p"/cards/#{ref}")

      broadcast(user, message(board))

      refute_push_event(view, "relay:notify", _)
      assert render(view)
    end

    test "browser_notify:open navigates to the card's board with ?card=", %{
      conn: conn,
      user: user,
      board: board
    } do
      {:ok, other_board} = Boards.create_board(user, %{name: "Marketing site"})
      {:ok, card} = Cards.create_card(backlog(other_board), %{title: "Elsewhere"})
      ref_c = Cards.ref(other_board, card)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view
      |> element("#browser-notify")
      |> render_hook("browser_notify:open", %{"board_slug" => other_board.slug, "card_ref" => ref_c})

      assert_redirect(view, "/board/#{other_board.slug}?card=#{ref_c}")
    end

    test "other messages still reach the LiveView (the hook continues for them)", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      {:ok, _card} = Cards.create_card(backlog(board), %{title: "Arrives live"})

      assert render(view) =~ "Arrives live"
    end
  end

  describe "on the admin session" do
    setup %{conn: conn} do
      admin = insert(:user, email: hd(Schemas.Scope.superadmin_emails()))
      %{conn: log_in_user(conn, admin), user: admin}
    end

    test "a superadmin on /admin receives relay:notify (no :embed assign there)", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/admin")

      broadcast(user, message(%{slug: "b", name: "B"}))

      assert_push_event(view, "relay:notify", _)
    end
  end
end
