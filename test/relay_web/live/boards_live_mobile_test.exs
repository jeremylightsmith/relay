defmodule RelayWeb.BoardsLiveMobileTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Relay.Factory

  alias Relay.Boards

  # RLY-95 · BOARDS-00 (docs/designs/Relay Mobile.dc.html lines ~371–393): below the
  # 45rem drawer breakpoint /boards is a single-column row list — compact "Boards"
  # title bar, accent chip + name + amber NEEDS YOU badge, and a mono meta line
  # `N stages · N cards · AI active|idle`. The DOM is width-independent (Tailwind
  # drawer: variants do the restyling), so these tests assert the markup contract.

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  describe "phone-width title bar" do
    test "renders the compact Boards heading; the desktop header is drawer-gated",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, "#boards-title-mobile", "Boards")
      assert view |> element("#boards-title-mobile") |> render() =~ "drawer:hidden"

      desktop = view |> element("#boards-desktop-header") |> render()
      assert desktop =~ "hidden"
      assert desktop =~ "drawer:flex"
    end
  end

  describe "board rows (BOARDS-00)" do
    test "meta line counts top-level stages and non-archived cards, idle with no working AI card",
         %{conn: conn, board: board} do
      spec = Enum.find(board.stages, &(&1.name == "Spec"))

      # A substage must not count toward "N stages" — only parent_id == nil does.
      insert(:stage,
        board: board,
        parent_id: spec.id,
        position: 99,
        category: :planning,
        type: :done,
        ai_enabled: false
      )

      insert(:card, board: board, stage: spec)

      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, "#board-meta-mobile-#{board.slug}", "8 stages · 1 cards · idle")
    end

    test "meta line says AI active when an agent is working a card",
         %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      card = insert(:card, board: board, stage: code, status: :working)
      insert(:card_owner, card: card)

      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, "#board-meta-mobile-#{board.slug}", "AI active")
    end

    test "the mobile meta line is drawer-gated and the desktop slug meta survives",
         %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert view |> element("#board-meta-mobile-#{board.slug}") |> render() =~ "drawer:hidden"

      card_html = view |> element("#board-card-#{board.slug}") |> render()
      assert card_html =~ "#{board.slug} · 0 cards"
    end
  end

  describe "NEEDS YOU badge count (ADR 0005)" do
    setup %{board: board} do
      backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
      code = Enum.find(board.stages, &(&1.name == "Code"))
      review = Enum.find(board.stages, &(&1.name == "Review"))

      insert(:card, board: board, stage: code, status: :needs_input)
      insert(:card, board: board, stage: review, status: :in_review)
      # Ready in Backlog: its puller (Next up) is not an AI work stage → awaiting-human.
      insert(:card, board: board, stage: backlog, status: :ready)

      :ok
    end

    test "web /boards shows the three-type count on both badges", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, "#board-needs-you-mobile-#{board.slug}", "3 NEEDS YOU")
      assert has_element?(view, "#board-needs-you-#{board.slug}", "3 need you")
    end

    test "embedded /boards shows the two-type count — it always agrees with the Needs-you tab",
         %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards?embed=1")

      assert has_element?(view, "#board-needs-you-mobile-#{board.slug}", "2 NEEDS YOU")
    end
  end

  describe "what phone width hides" do
    test "the New-board tile is drawer-gated (board building is not mobile)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      tile = view |> element("#new-board-button") |> render()
      assert tile =~ "hidden"
      assert tile =~ "drawer:flex"
    end

    test "the member/updated footer row is drawer-gated", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      foot = view |> element("#board-card-foot-#{board.slug}") |> render()
      assert foot =~ "hidden"
      assert foot =~ "drawer:flex"
    end
  end
end
