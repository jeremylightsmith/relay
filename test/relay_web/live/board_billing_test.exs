defmodule RelayWeb.BoardBillingTest do
  # RE460 — a board's standing is its owner's: a past-due owner sees a banner on a fully editable
  # board; a paused owner's board is read-only for every member (no card opening, no Board
  # settings), and comes back live when the owner pays.
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Billing
  alias Relay.Boards
  alias Relay.Cards

  @paused_flash "This board&#39;s plan is paused (read-only)."

  setup :register_and_log_in_user

  setup %{user: user} do
    Process.put(:billing_enabled, true)
    {:ok, board} = Boards.create_board(user, %{name: "Billed", key: "RL"})
    stage = hd(board.stages)
    {:ok, card} = Cards.create_card(stage, %{title: "First"})
    %{board: board, stage: stage, card: card, today: Date.utc_today()}
  end

  defp past_due!(user, today),
    do: insert(:billing_account, user: user, paid_through: Date.add(today, -1), billing_day: today.day)

  defp paused!(user, today),
    do: insert(:billing_account, user: user, paid_through: Date.add(today, -10), billing_day: today.day)

  defp create_card(view, stage, title) do
    render_hook(view, "create_card", %{"stage_id" => "#{stage.id}", "card" => %{"title" => title}})
  end

  defp titles(board), do: board |> Cards.list_cards() |> Enum.map(& &1.title) |> Enum.sort()

  defp member_conn(board) do
    member = insert(:user)
    insert(:membership, board: board, user: member)
    log_in_user(build_conn(), member)
  end

  test "a past-due owner gets the banner on an editable board (scenario 12)", %{
    conn: conn,
    user: user,
    board: board,
    stage: stage,
    today: today
  } do
    past_due!(user, today)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    assert has_element?(
             view,
             "#billing-past-due-banner.rounded-lg.px-4.text-sm",
             "Your card was declined. Update it today to keep your boards editable."
           )

    assert has_element?(view, ~s(#billing-past-due-update-card.btn.btn-sm[href="/account/billing"]), "Update card")
    refute has_element?(view, "#read-only-banner")

    create_card(view, stage, "Still editable")
    assert "Still editable" in titles(board)
  end

  test "a paused owner gets the read-only banner, no Restore, no settings (scenario 13)", %{
    conn: conn,
    user: user,
    board: board,
    today: today
  } do
    paused!(user, today)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    assert has_element?(view, "#read-only-banner b", "Your plan is paused, so this board is read-only.")

    assert view |> element("#read-only-banner") |> render() =~
             "Nothing&#39;s been deleted. Pay to pick up where you left off."

    assert has_element?(
             view,
             ~s(#billing-paused-update-card.btn.btn-warning.btn-sm[href="/account/billing"]),
             "Update card"
           )

    refute has_element?(view, "#restore-board-button")
    refute has_element?(view, "#board-settings-link")
  end

  test "a paused board refuses writes with the paused flash (scenario 14)", %{
    conn: conn,
    user: user,
    board: board,
    stage: stage,
    today: today
  } do
    paused!(user, today)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    assert create_card(view, stage, "sneaky") =~ @paused_flash
    assert titles(board) == ["First"]

    other = Enum.at(board.stages, 1)
    html = render_hook(view, "move_card", %{"ref" => "RL1", "stage_id" => other.id, "index" => 0})
    assert html =~ @paused_flash
    assert [%{stage_id: stage_id}] = Cards.list_cards(board)
    assert stage_id == stage.id
  end

  test "a paused board opens no card (scenario 15)", %{conn: conn, user: user, board: board, today: today} do
    paused!(user, today)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RL1")

    refute has_element?(view, "#card-drawer")
    assert has_element?(view, "#read-only-banner")

    render_click(view, "select_card", %{"ref" => "RL1"})
    refute has_element?(view, "#card-drawer")
    %{proxy: {ref, topic, _}} = view
    refute_received {^ref, {:patch, ^topic, _opts}}
  end

  describe "a member of the owner's board (scenario 16)" do
    test "sees the owner's paused copy, no button, no settings, no drawer", %{user: user, board: board, today: today} do
      paused!(user, today)
      {:ok, view, _html} = live(member_conn(board), ~p"/board/#{board.slug}?card=RL1")

      assert has_element?(view, "#read-only-banner", "This board's owner's plan is paused.")
      refute has_element?(view, "#billing-paused-update-card")
      refute has_element?(view, "#board-settings-link")
      refute has_element?(view, "#card-drawer")
    end

    test "sees no past-due banner", %{user: user, board: board, today: today} do
      past_due!(user, today)
      {:ok, view, _html} = live(member_conn(board), ~p"/board/#{board.slug}")

      refute has_element?(view, "#billing-past-due-banner")
      refute has_element?(view, "#read-only-banner")
    end
  end

  test "paying un-pauses the open board live (scenario 17)", %{
    conn: conn,
    user: user,
    board: board,
    stage: stage,
    today: today
  } do
    paused!(user, today)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    assert has_element?(view, "#read-only-banner")

    {:ok, %{charged: :paid}} = Billing.complete_setup("local_4242_#{user.id}", user.id, today)

    refute has_element?(view, "#read-only-banner")
    create_card(view, stage, "Back in business")
    assert "Back in business" in titles(board)
  end

  test "a board that pauses while a card is open closes the drawer", %{
    conn: conn,
    user: user,
    board: board,
    today: today
  } do
    account = insert(:billing_account, user: user, paid_through: Date.add(today, 5), billing_day: today.day)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RL1")
    assert has_element?(view, "#card-drawer")

    account |> Ecto.Changeset.change(paid_through: Date.add(today, -10)) |> Relay.Repo.update!()
    :ok = Billing.broadcast_changed(user.id)

    assert_patch(view, "/board/#{board.slug}")
    refute has_element?(view, "#card-drawer")
    assert has_element?(view, "#read-only-banner")
  end

  test "billing disabled: no banner and writes work (scenario 18)", %{
    conn: conn,
    user: user,
    board: board,
    stage: stage,
    today: today
  } do
    Process.put(:billing_enabled, false)
    insert(:billing_account, user: user, paid_through: Date.add(today, -365), billing_day: today.day)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    refute has_element?(view, "#read-only-banner")
    refute has_element?(view, "#billing-past-due-banner")
    create_card(view, stage, "Self-hosted")
    assert "Self-hosted" in titles(board)
  end

  test "a paused and archived board shows the paused copy (scenario 19)", %{
    conn: conn,
    user: user,
    board: board,
    today: today
  } do
    paused!(user, today)
    {:ok, _board} = Boards.archive_board(board)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    banner = view |> element("#read-only-banner") |> render()
    assert banner =~ "Your plan is paused, so this board is read-only."
    refute banner =~ "This board is archived and read-only."
  end

  describe "embedded in the native app (RE466)" do
    test "a paused owner's banner keeps its copy but drops Update card", %{
      conn: conn,
      user: user,
      board: board,
      today: today
    } do
      paused!(user, today)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

      assert has_element?(view, "#read-only-banner b", "Your plan is paused, so this board is read-only.")
      refute has_element?(view, "#billing-paused-update-card")
      refute view |> element("#read-only-banner") |> render() =~ ~s(href="/account/billing")
    end

    test "a past-due owner's banner keeps its copy but drops Update card", %{
      conn: conn,
      user: user,
      board: board,
      today: today
    } do
      past_due!(user, today)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

      assert has_element?(
               view,
               "#billing-past-due-banner",
               "Your card was declined. Update it today to keep your boards editable."
             )

      refute has_element?(view, "#billing-past-due-update-card")
      refute view |> element("#billing-past-due-banner") |> render() =~ ~s(href="/account/billing")
    end

    test "outside the app the paused banner still offers Update card", %{
      conn: conn,
      user: user,
      board: board,
      today: today
    } do
      paused!(user, today)

      {:ok, plain, _html} = live(conn, ~p"/board/#{board.slug}")
      assert has_element?(plain, ~s(#billing-paused-update-card[href="/account/billing"]), "Update card")

      {:ok, left_embed, _html} = live(conn, ~p"/board/#{board.slug}?embed=0")
      assert has_element?(left_embed, ~s(#billing-paused-update-card[href="/account/billing"]), "Update card")
    end
  end
end
