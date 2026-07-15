defmodule RelayWeb.BoardLiveDoneLimitTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    done = Boards.terminal_stage(board.stages)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    %{board: board, done: done, code: code}
  end

  # Seed n cards into the terminal Done stage with ascending updated_at, so
  # "Done n" is the newest and "Done 1" the oldest.
  defp seed_done_cards(done, n) do
    for i <- 1..n do
      insert(:card,
        stage: done,
        title: "Done #{i}",
        updated_at: DateTime.add(~U[2026-07-01 00:00:00Z], i, :second)
      )
    end
  end

  defp card_count(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  defp card_titles(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  describe "terminal Done column windowing" do
    test "renders only the newest 8 cards", %{conn: conn, board: board, done: done} do
      seed_done_cards(done, 12)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      titles = card_titles(view, "#stage-col-#{done.position}-cards .board-card .card-title")
      assert length(titles) == 8
      assert "Done 12" in titles
      assert "Done 5" in titles
      refute "Done 4" in titles
      refute "Done 1" in titles
    end

    test "the newest completed card is at the top of the window",
         %{conn: conn, board: board, done: done} do
      seed_done_cards(done, 12)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert [first | _] = card_titles(view, "#stage-col-#{done.position}-cards .board-card .card-title")
      assert first == "Done 12"
    end
  end

  describe "Show more button" do
    test "appears with the next-batch count when Done exceeds 8",
         %{conn: conn, board: board, done: done} do
      seed_done_cards(done, 12)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-col-#{done.position}-show-more-done")
      # 12 total − 8 shown = 4 hidden, batch capped at 8 → "Show 4 more"
      label = view |> element("#stage-col-#{done.position}-show-more-done") |> render()
      assert label =~ "Show"
      assert label =~ "4"
    end

    test "is absent when Done has 8 or fewer cards",
         %{conn: conn, board: board, done: done} do
      seed_done_cards(done, 8)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert card_count(view, "#stage-col-#{done.position}-cards .board-card") == 8
      refute has_element?(view, "#stage-col-#{done.position}-show-more-done")
    end

    test "clicking reveals the next batch and updates the label until none remain",
         %{conn: conn, board: board, done: done} do
      seed_done_cards(done, 20)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert card_count(view, "#stage-col-#{done.position}-cards .board-card") == 8
      assert view |> element("#stage-col-#{done.position}-show-more-done") |> render() =~ "8"

      view |> element("#stage-col-#{done.position}-show-more-done") |> render_click()

      assert card_count(view, "#stage-col-#{done.position}-cards .board-card") == 16
      # 20 − 16 = 4 hidden → "Show 4 more"
      assert view |> element("#stage-col-#{done.position}-show-more-done") |> render() =~ "4"

      view |> element("#stage-col-#{done.position}-show-more-done") |> render_click()

      assert card_count(view, "#stage-col-#{done.position}-cards .board-card") == 20
      refute has_element?(view, "#stage-col-#{done.position}-show-more-done")
    end
  end

  describe "Show more button placement" do
    # RLY-53 rejection: the button rendered *inside* the lane's scroll
    # container, after the #...-cards div. That div carries min-height:100%
    # (RLY-1's full-height drop zone), so it always fills the scroll viewport
    # and pushed the button past the bottom edge — a 3px sliver, 45px of
    # scrolling away. has_element?/2 passed the whole time because the button
    # was in the DOM; only its position was wrong. Keep it out of the scroller.
    test "the button is not trapped inside the lane's scroll container",
         %{conn: conn, board: board, done: done} do
      seed_done_cards(done, 12)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      doc = view |> render() |> LazyHTML.from_fragment()

      assert doc
             |> LazyHTML.query("#stage-col-#{done.position}-show-more-done")
             |> Enum.count() == 1

      assert doc
             |> LazyHTML.query("#stage-col-#{done.position}-scroll #stage-col-#{done.position}-show-more-done")
             |> Enum.count() == 0,
             "the Show more button is inside the scroll container, where the " <>
               "min-height:100% drop zone pushes it out of view"
    end
  end

  describe "scope" do
    test "a Done sub-lane with more than 8 cards is not limited",
         %{conn: conn, board: _board, code: code, user: user} do
      {:ok, sub} = Boards.enable_lane(code, :done)
      for i <- 1..9, do: insert(:card, stage: sub, title: "Sub #{i}")

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert card_count(view, "#sublane-#{sub.id}-cards .board-card") == 9
      refute has_element?(view, "#sublane-#{sub.id}-show-more-done")
    end
  end

  describe "realtime" do
    test "a card moved into Done appears on top and keeps the count consistent",
         %{conn: conn, board: board, done: done, code: code} do
      seed_done_cards(done, 8)
      {:ok, mover} = Cards.create_card(code, %{title: "Fresh finish"})

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      refute has_element?(view, "#stage-col-#{done.position}-show-more-done")

      {:ok, _moved} = Cards.move_card(mover, done, 0)

      # broadcast applied: the 9th card is revealed on top, nothing hidden.
      assert card_count(view, "#stage-col-#{done.position}-cards .board-card") == 9
      refute has_element?(view, "#stage-col-#{done.position}-show-more-done")

      assert [first | _] =
               card_titles(view, "#stage-col-#{done.position}-cards .board-card .card-title")

      assert first == "Fresh finish"
    end
  end
end
