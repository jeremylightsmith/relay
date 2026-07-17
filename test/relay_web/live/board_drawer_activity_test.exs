defmodule RelayWeb.BoardDrawerActivityTest do
  use RelayWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Repo

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: "Migrate 40 blog posts"})
    %{board: board, card: card, ref: Cards.ref(board, card)}
  end

  defp claim_ai(card) do
    {:ok, card} = Cards.assign_ai(card)
    {:ok, card} = Cards.set_status(card, %{status: :working})
    card
  end

  # The drawer body loads async (RLY-68): without render_async the Activity section
  # is still a skeleton and every assertion below would miss.
  defp open(conn, board, ref) do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
    render_async(view)
    view
  end

  # `LazyHTML.filter/2` only matches the fragment's ROOT nodes; the activity <li>s
  # are deeply nested, so `query/2` (descendant search) is the correct call here.
  defp entries(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".activity-entry")
  end

  test "a move renders as an inline chip, and the newer log line sits above it", %{
    conn: conn,
    board: board,
    card: card,
    ref: ref
  } do
    earlier = DateTime.utc_now() |> DateTime.add(-14 * 60, :second) |> DateTime.truncate(:second)

    insert(:activity,
      card: card,
      type: :moved,
      meta: %{"from_stage" => "Review", "to_stage" => "Build"},
      inserted_at: earlier
    )

    insert(:activity, card: card, type: :action, text: "uploaded 24/40 posts")

    view = open(conn, board, ref)
    html = render(view)

    assert has_element?(view, ".activity-move-chip")
    assert html =~ "Review → Build"

    # Newest-first: the log line's row precedes the move chip's row in the DOM.
    {line_at, _} = :binary.match(html, "uploaded 24/40 posts")
    {chip_at, _} = :binary.match(html, "activity-move-chip")
    assert line_at < chip_at
  end

  test "a failure row renders rose and shows its text", %{conn: conn, board: board, card: card, ref: ref} do
    insert(:activity, card: card, type: :failure, text: "agent stopped")

    view = open(conn, board, ref)

    assert has_element?(view, ".activity-entry[data-kind='failure']")
    assert render(view) =~ "agent stopped"
  end

  test "an action row renders violet and shows its raw text", %{conn: conn, board: board, card: card, ref: ref} do
    insert(:activity, card: card, type: :action, text: "🔧 Edit  lib/relay/cards.ex")

    view = open(conn, board, ref)

    assert has_element?(view, ".activity-entry[data-kind='action']")
    assert render(view) =~ "🔧 Edit  lib/relay/cards.ex"
  end

  # Audit rows carry no `text`, so they must fall back to the drawer's sentence.
  # create_card/2 already logged a :created entry in setup.
  test "an audit row with no text still renders its sentence", %{conn: conn, board: board, ref: ref} do
    view = open(conn, board, ref)

    assert render(view) =~ "created this card"
  end

  test "the section header carries the live health chip, and no Retry", %{
    conn: conn,
    board: board,
    card: card,
    ref: ref
  } do
    card = claim_ai(card)
    insert(:activity, card: card, type: :action, text: "uploaded 24/40 posts")

    view = open(conn, board, ref)

    assert has_element?(view, "#card-drawer-activity-health-chip[data-health='live']")
    assert render(view) =~ "Relay AI is live"
    refute render(view) =~ "Retry"
  end

  test "the health chip goes amber when the agent goes quiet past STALE_AFTER", %{
    conn: conn,
    board: board,
    card: card,
    ref: ref
  } do
    card = claim_ai(card)
    insert(:activity, card: card, type: :action, text: "reindexing 12k documents")
    quiet = DateTime.utc_now() |> DateTime.add(-3 * 60, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(a in Schemas.Activity, where: a.card_id == ^card.id), set: [inserted_at: quiet])

    view = open(conn, board, ref)

    assert has_element?(view, "#card-drawer-activity-health-chip[data-health='stale']")
    chip = view |> element("#card-drawer-activity-health-chip") |> render()
    assert chip =~ "Relay AI has gone quiet"
    assert chip =~ "var(--color-warning)"
  end

  test "the health chip goes rose on a failure, still with no Retry", %{
    conn: conn,
    board: board,
    card: card,
    ref: ref
  } do
    card = claim_ai(card)
    insert(:activity, card: card, type: :failure, text: "agent stopped")

    view = open(conn, board, ref)

    assert has_element?(view, "#card-drawer-activity-health-chip[data-health='stopped']")
    refute render(view) =~ "Retry"
  end

  test "no chip renders for a card with no active agent", %{conn: conn, board: board, ref: ref} do
    view = open(conn, board, ref)

    refute has_element?(view, "#card-drawer-activity-health-chip")
  end

  # Q4 bounds storage over time; this bounds ONE render. The artboard rules a
  # filter/expand toggle out of v1, so without a cap a card mid-run would try to
  # paint thousands of rows into the drawer.
  test "the drawer render cap holds at 200 rows", %{conn: conn, board: board, card: card, ref: ref} do
    base = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

    for i <- 1..205 do
      insert(:activity, card: card, type: :action, text: "line #{i}", inserted_at: DateTime.add(base, i, :second))
    end

    view = open(conn, board, ref)

    # 206 rows exist (205 lines + setup's :created); exactly the newest 200 render.
    # The count IS the assertion — a text refute would false-match ("line 1" hits
    # "line 10", "line 100", …).
    assert Enum.count(entries(view)) == 200
    assert render(view) =~ "line 205"
  end
end
