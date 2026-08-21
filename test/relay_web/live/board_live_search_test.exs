defmodule RelayWeb.BoardLiveSearchTest do
  @moduledoc """
  RE198 — the board header's card search. A results POPOVER, deliberately not a column filter:
  the columns are LiveView streams and the terminal Done column renders only a bounded window,
  so filtering the columns would structurally fail to find most Done cards. These tests pin
  both halves of that — results appear, and the board itself never loses a card.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    [backlog | _] = Boards.list_stages(board)
    {:ok, found} = Cards.create_card(backlog, %{title: "Story map filter focus"})
    {:ok, other} = Cards.create_card(backlog, %{title: "Unrelated work"})
    %{board: board, backlog: backlog, found: found, other: other}
  end

  defp search(view, query) do
    view |> form("#board-search-form", %{"q" => query}) |> render_change()
  end

  test "the box renders in the board header with the header control idiom",
       %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    input = view |> element("#board-search-input") |> render()

    assert input =~ "input input-sm"
    assert input =~ "min-h-[44px]"
    assert input =~ ~s(name="q")
    refute has_element?(view, "#board-search-results")
  end

  test "typing shows matching rows with their ref and stage", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    search(view, "story map")

    assert has_element?(view, "#board-search-results")
    assert has_element?(view, "#board-search-result-MY1", "Story map filter focus")
    assert has_element?(view, "#board-search-result-MY1", "Backlog")
    refute has_element?(view, "#board-search-result-MY2")
  end

  test "a ref query finds the card", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    search(view, "MY2")

    assert has_element?(view, "#board-search-result-MY2", "Unrelated work")
  end

  test "no matches renders the no-match copy and no rows", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    search(view, "zzzznotarealcard")

    assert has_element?(view, "#board-search-empty", ~s(No cards match "zzzznotarealcard".))
    refute has_element?(view, "#board-search-result-MY1")
  end

  test "the board keeps every card while searching", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    search(view, "zzzznotarealcard")
    board_html = view |> element("#board") |> render()

    assert board_html =~ "Story map filter focus"
    assert board_html =~ "Unrelated work"
  end

  test "a Done card the column does not render is still findable", %{conn: conn, board: board} do
    done = Boards.terminal_stage(board.stages)

    insert(:card,
      stage: done,
      title: "Zebra archaeology",
      ref_number: 100,
      updated_at: ~U[2026-07-01 00:00:00Z]
    )

    for i <- 1..12 do
      insert(:card,
        stage: done,
        title: "Filler #{i}",
        ref_number: 100 + i,
        updated_at: DateTime.add(~U[2026-07-01 00:00:00Z], i, :second)
      )
    end

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    # The terminal Done column renders only the newest `Cards.done_page_size/0` cards, so the
    # oldest is not in the stream at all. This is exactly why search is a popover over the
    # database and not a filter over the columns.
    refute view |> element("#board") |> render() =~ "Zebra archaeology"

    search(view, "zebra")

    assert has_element?(view, "#board-search-results", "Zebra archaeology")
  end

  test "a full page of results renders the keep-typing footer", %{conn: conn, board: board, backlog: backlog} do
    for n <- 1..9, do: {:ok, _} = Cards.create_card(backlog, %{title: "widget #{n}"})

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    search(view, "widget")

    assert has_element?(view, "#board-search-more", "Showing the first 8")
  end

  test "a partial page renders no footer", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    search(view, "story map")

    refute has_element?(view, "#board-search-more")
  end

  test "clicking a row opens that card's drawer and clears the box",
       %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    search(view, "story map")
    view |> element("#board-search-result-MY1") |> render_click()

    assert_patch(view, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)
    assert has_element?(view, "#card-drawer")
    assert has_element?(view, "#card-drawer-title-display", "Story map filter focus")
    refute has_element?(view, "#board-search-results")
  end

  test "Enter opens the first result", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    search(view, "story map")
    view |> form("#board-search-form", %{"q" => "story map"}) |> render_submit()

    assert_patch(view, ~p"/board/#{board.slug}?card=MY1")
  end

  test "Enter with no results does nothing", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    search(view, "zzzznotarealcard")
    view |> form("#board-search-form", %{"q" => "zzzznotarealcard"}) |> render_submit()

    assert has_element?(view, "#board-search-empty")
  end

  test "Escape closes the popover", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    search(view, "story map")
    view |> element("#board-search") |> render_keydown(%{"key" => "Escape"})

    refute has_element?(view, "#board-search-results")
    assert view |> element("#board-search-input") |> render() =~ ~s(value="")
  end

  test "an archived hit is never in the header search — that has its own browser",
       %{conn: conn, board: board, other: other} do
    {:ok, _archived} = Cards.archive_card(other, :agent)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    search(view, "unrelated")

    assert has_element?(view, "#board-search-empty")
  end

  test "the box is absent on the embedded board", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

    refute has_element?(view, "#board-search")
  end

  test "search works on an archived, read-only board — it is itself read-only",
       %{conn: conn, board: board} do
    {:ok, board} = Boards.archive_board(board)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    search(view, "story map")

    assert has_element?(view, "#board-search-result-MY1")
    refute render(view) =~ "This board is archived (read-only)."
  end
end
