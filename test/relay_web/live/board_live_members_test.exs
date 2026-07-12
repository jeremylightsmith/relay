defmodule RelayWeb.BoardLiveMembersTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Members

  setup :register_and_log_in_user

  test "the reassign picker lists every resolved member and Relay AI", %{conn: conn, user: user} do
    board = Boards.get_or_create_default_board(user)
    teammate = insert(:user, name: "Morgan Lee")
    insert(:membership, board: board, user: teammate, email: teammate.email)
    [stage | _] = board.stages
    card = insert(:card, stage: stage)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}")

    view |> element("#card-drawer-reassign-toggle") |> render_click()
    assert has_element?(view, "#card-drawer-reassign-picker")
    assert has_element?(view, "#card-drawer-assign-user-#{user.id}")
    assert has_element?(view, "#card-drawer-assign-user-#{teammate.id}")
    assert has_element?(view, "#card-drawer-assign-ai")
  end

  test "the reassign picker's person avatars match the mockup's chroma", %{conn: conn, user: user} do
    board = Boards.get_or_create_default_board(user)
    [stage | _] = board.stages
    card = insert(:card, stage: stage)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}")

    view |> element("#card-drawer-reassign-toggle") |> render_click()
    row = view |> element("#card-drawer-assign-user-#{user.id} span[style*='border-radius:50%']") |> render()

    # matches `docs/designs/Relay Board.dc.html` avatarFor/mkAvatar (lines ~1166, ~1194):
    # oklch(0.62 0.13 <hue>), never 0.15
    assert row =~ "background:oklch(0.62 0.13 "
  end

  test "picking a member assigns them as the active owner", %{conn: conn, user: user} do
    board = Boards.get_or_create_default_board(user)
    teammate = insert(:user, name: "Morgan Lee")
    insert(:membership, board: board, user: teammate, email: teammate.email)
    [stage | _] = board.stages
    card = insert(:card, stage: stage)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}")

    view |> element("#card-drawer-reassign-toggle") |> render_click()
    view |> element("#card-drawer-assign-user-#{teammate.id}") |> render_click()

    card = Cards.get_card_by_ref(board, Cards.ref(board, card))
    assert Cards.active_owner_type(card) == :human
    assert Enum.any?(card.owners, &(&1.actor_type == :user and &1.user_id == teammate.id))
  end

  test "picking a non-member id is a no-op", %{conn: conn, user: user} do
    board = Boards.get_or_create_default_board(user)
    [stage | _] = board.stages
    card = insert(:card, stage: stage)
    stranger = insert(:user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}")

    render_hook(view, "add_owner", %{"actor_type" => "user", "user_id" => to_string(stranger.id)})

    card = Cards.get_card_by_ref(board, Cards.ref(board, card))
    refute Enum.any?(card.owners, &(&1.user_id == stranger.id))
  end

  test "a removed member's open board session is redirected to /boards", %{conn: conn, user: user} do
    board = Boards.get_or_create_default_board(user)
    [membership] = Members.list_members(board)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    {:ok, _} = Members.remove(membership)

    assert_redirect(view, ~p"/boards")
  end
end
