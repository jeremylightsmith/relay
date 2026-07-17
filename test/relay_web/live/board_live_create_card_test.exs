defmodule RelayWeb.BoardLiveCreateCardTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  # group_stages/flat_stages order: category bands in fixed order, board position within.
  defp expected_top_level_names(board) do
    for category <- [:unstarted, :planning, :in_progress, :complete],
        stage <- Enum.filter(board.stages, &(is_nil(&1.parent_id) and &1.category == category)),
        do: stage.name
  end

  describe "embed board (?embed=1) — the native create path" do
    test "renders #board-create-card with the bridge payload data attributes", %{
      conn: conn,
      user: user,
      board: board
    } do
      # A substage proves data-stages carries top-level stages ONLY.
      {:ok, _review} = Boards.enable_lane(hd(board.stages), :review)
      board = Boards.get_board!(user, board.slug)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

      doc = view |> render() |> LazyHTML.from_fragment()
      # `LazyHTML.filter/2` only matches the fragment's ROOT nodes; the button is deeply
      # nested, so `query/2` (descendant search) is the correct call here.
      button = LazyHTML.query(doc, "#board-create-card")

      assert LazyHTML.attribute(button, "data-board") == [board.slug]

      [stages_json] = LazyHTML.attribute(button, "data-stages")
      expected = expected_top_level_names(board)
      assert Jason.decode!(stages_json) == expected
      refute Enum.any?(Jason.decode!(stages_json), &String.contains?(&1, ":"))
    end

    test "pager chips carry data-stage-name for the hook's current-stage lookup", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

      doc = view |> render() |> LazyHTML.from_fragment()

      names =
        doc
        |> LazyHTML.query("#board-pager-nav [data-chip-stage-id]")
        |> LazyHTML.attribute("data-stage-name")

      assert names == expected_top_level_names(board)
    end

    test "hides the inline composer — the header + is the app's only create path", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

      # A fresh board's empty stages render collapsed (MMF 12c) — the header compose
      # control (`.stage-compose`) only exists once a stage is expanded. Expand one so
      # this refute actually exercises the `composable={not @embed}` gate instead of
      # passing vacuously because the header never rendered at all.
      [backlog | _] = board.stages
      view |> element("#stage-strip-#{backlog.id}") |> render_click()

      refute has_element?(view, ".stage-compose")
      assert has_element?(view, "#board-create-card")
    end
  end

  describe "non-embed board — web is untouched" do
    test "keeps the inline composer and renders no header +", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      # A fresh board's empty stages render collapsed (MMF 12c); expand one to reach its
      # header compose control.
      [backlog | _] = board.stages
      view |> element("#stage-strip-#{backlog.id}") |> render_click()

      assert has_element?(view, ".stage-compose")
      refute has_element?(view, "#board-create-card")
    end
  end
end
