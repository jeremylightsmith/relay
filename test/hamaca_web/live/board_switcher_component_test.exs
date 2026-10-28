defmodule HamacaWeb.BoardSwitcherComponentTest.Host do
  @moduledoc false
  # A minimal LiveView hosting the board bar's title, so the switcher LiveComponent runs
  # exactly as a board page will mount it (through `BoardBarComponents.board_bar_title/1`).
  use HamacaWeb, :live_view

  alias HamacaWeb.BoardBarComponents

  @impl true
  def mount(_params, %{"board" => board, "user" => user}, socket) do
    {:ok, assign(socket, board: board, user: user)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <BoardBarComponents.board_bar_title board={@board} user={@user} active_view={:board} />
    """
  end
end

defmodule HamacaWeb.BoardSwitcherComponentTest do
  use HamacaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias HamacaWeb.BoardSwitcherComponentTest.Host

  # RE497: the switcher loads `Cards.list_board_summaries/1` on its first open only — never at
  # mount, since that call reads every card of every board — and caches the rows for the mount.

  defp member_board(user, name, key) do
    board = insert(:board, name: name, key: key)
    insert(:membership, board: board, user: user)
    board
  end

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[id^=board-switcher-row-]")
    |> LazyHTML.attribute("id")
  end

  setup %{conn: conn} do
    user = insert(:user)
    zeta = member_board(user, "zeta", "ZZ")
    alpha = member_board(user, "Alpha", "AL")
    mango = member_board(user, "mango", "MA")
    {:ok, true} = Hamaca.Boards.set_starred(user, zeta.slug, true)

    review = insert(:stage, board: zeta, name: "Review", type: :review, position: 1)
    insert(:card, stage: review, status: :in_review)

    code = insert_ai_stage(board: mango, name: "Code", position: 1)
    working = insert(:card, stage: code, status: :working)
    insert(:card_owner, card: working)

    {:ok, view, _html} =
      live_isolated(conn, Host, session: %{"board" => alpha, "user" => user})

    %{view: view, user: user, zeta: zeta, alpha: alpha, mango: mango}
  end

  test "mounts with the board name and no rows: summaries are not loaded at mount", %{view: view} do
    assert view |> element("#board-name") |> render() =~ "Alpha"
    assert row_ids(view) == []
  end

  test "the view switch sits beside the switcher, wide only", %{view: view} do
    assert has_element?(view, "div.hidden.sm\\:flex #board-view-tabs")
  end

  test "the first open loads the rows, starred first then A–Z", %{view: view} = ctx do
    view |> element("#board-switcher-button") |> render_click()

    assert row_ids(view) == [
             "board-switcher-row-#{ctx.zeta.slug}",
             "board-switcher-row-#{ctx.alpha.slug}",
             "board-switcher-row-#{ctx.mango.slug}"
           ]

    assert has_element?(view, ~s(#board-switcher-row-#{ctx.alpha.slug}[aria-current="page"]))

    badge =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#board-switcher-row-#{ctx.zeta.slug} .badge-primary")

    assert badge |> LazyHTML.text() |> String.trim() == "1"

    assert has_element?(view, "#board-switcher-row-#{ctx.mango.slug} .bg-secondary")
  end

  test "a second open is a no-op: the rows are cached for the mount", %{view: view, user: user} = ctx do
    view |> element("#board-switcher-button") |> render_click()
    late = member_board(user, "beta", "BE")

    view |> element("#board-switcher-button") |> render_click()

    refute has_element?(view, "#board-switcher-row-#{late.slug}")
    assert length(row_ids(view)) == 3
    assert has_element?(view, "#board-switcher-row-#{ctx.zeta.slug}")
  end
end
