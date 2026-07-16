defmodule RelayWeb.BoardSettingsMembersTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Members
  alias Relay.Repo

  setup :register_and_log_in_user

  defp board_for(user), do: Boards.get_or_create_default_board(user)

  test "the Members nav link renders and opens the members pane", %{conn: conn, user: user} do
    board = board_for(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=members")

    assert has_element?(view, "#settings-nav-members")
    assert has_element?(view, "#members-pane")
    assert has_element?(view, "#invite-member-form")
  end

  test "the current user's own row shows a YOU badge and no remove button", %{conn: conn, user: user} do
    board = board_for(user)
    [me] = Members.list_members(board)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=members")

    assert has_element?(view, "#member-row-#{me.id}", "YOU")
    refute has_element?(view, "#remove-member-#{me.id}")
  end

  test "inviting an email adds an INVITED row", %{conn: conn, user: user} do
    board = board_for(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=members")

    view
    |> form("#invite-member-form", invite: %{email: "teammate@example.com"})
    |> render_submit()

    [invited] = Enum.filter(Members.list_members(board), &(&1.user_id == nil))
    assert has_element?(view, "#member-row-#{invited.id}", "INVITED")
    assert has_element?(view, "#member-row-#{invited.id}", "teammate@example.com")
  end

  test "a duplicate invite surfaces a flash", %{conn: conn, user: user} do
    board = board_for(user)
    {:ok, _} = Members.invite(board, "dup@example.com")
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=members")

    html =
      view
      |> form("#invite-member-form", invite: %{email: "dup@example.com"})
      |> render_submit()

    assert html =~ "already"
  end

  test "removing another member drops the row", %{conn: conn, user: user} do
    board = board_for(user)
    other = insert(:user, name: "Other")
    membership = insert(:membership, board: board, user: other, email: other.email)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=members")

    assert has_element?(view, "#member-row-#{membership.id}")
    view |> element("#remove-member-#{membership.id}") |> render_click()
    refute has_element?(view, "#member-row-#{membership.id}")
  end

  test "a non-owner member can open settings and edit stages (no role gate)", %{conn: conn, user: user} do
    owner = insert(:user)
    board = Boards.get_or_create_default_board(owner)
    insert(:membership, board: board, user: user, email: user.email)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=stages")
    assert has_element?(view, "#stages-pane")
    assert has_element?(view, "#settings-nav-members")
  end

  test "a member row's avatar matches the mockup's chroma and font size", %{conn: conn, user: user} do
    # RLY-90: without a photo, the row falls back to the identity-tinted initials circle.
    user |> Ecto.Changeset.change(avatar_url: nil) |> Repo.update!()
    board = board_for(user)
    [me] = Members.list_members(board)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=members")

    row = view |> element("#member-row-#{me.id} span[style*='border-radius:50%']") |> render()

    # matches `docs/designs/Relay Board.dc.html` member row avatarStyle (line ~1406):
    # oklch(0.62 0.13 <hue>) at the shared avatar's size-derived font (round(34*0.42) = 14px)
    assert row =~ "background:oklch(0.62 0.13 "
    assert row =~ "font-size:14px"
  end

  test "the AGENT card links to the API keys pane", %{conn: conn, user: user} do
    board = board_for(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=members")

    assert has_element?(view, "#agent-card")

    assert has_element?(
             view,
             ~s{#agent-card a[href="/board/#{board.slug}/settings?section=keys"]}
           )
  end

  test "the AGENT card subtitle matches the mockup's AI-owned wording", %{conn: conn, user: user} do
    board = board_for(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=members")

    # matches `docs/designs/Relay Board.dc.html:455`: "Runs the AI-owned stages · authenticated with an API key"
    assert has_element?(view, "#agent-card", "Runs the AI-owned stages")
    refute render(view) =~ "AI-enabled stages"
  end

  test "the API keys pane intro matches the mockup's AI-owned wording", %{conn: conn, user: user} do
    board = board_for(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=keys")

    # matches `docs/designs/Relay Board.dc.html:464`
    assert has_element?(view, "#api-key-pane", "ask questions on the AI-owned stages")
    refute render(view) =~ "AI-enabled stages"
  end
end
