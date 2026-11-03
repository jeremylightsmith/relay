defmodule HamacaWeb.BoardLiveDoneWeeksTest do
  @moduledoc """
  RE504 — the terminal Done column pages by whole ISO weeks of effective done time, read in the
  viewer's time zone, with a week marker stream item before each week's cards. Replaces RLY-53's
  count paging ("Show N more"). Week starts are computed from the real clock so the tests pass
  on any weekday.
  """
  use HamacaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Hamaca.Activity
  alias Hamaca.Boards
  alias Hamaca.Cards
  alias Hamaca.Cards.DoneWeeks
  alias Hamaca.Repo
  alias Schemas.Card

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    done = Boards.terminal_stage(board.stages)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    monday = DoneWeeks.week_start(DateTime.utc_now(), "Etc/UTC")
    %{board: board, done: done, code: code, monday: monday, col: "stage-col-#{done.position}"}
  end

  # A done_at in the week `offset` weeks from this week (0 = this week, -1 = last week, …).
  # This week's cards sit in the first seconds of Monday so they are never in the future
  # relative to a card moved into Done "now"; older weeks sit mid-week.
  defp done_at(monday, 0, i), do: DateTime.new!(monday, Time.new!(0, 0, i), "Etc/UTC")

  defp done_at(monday, offset, i) do
    monday |> Date.add(7 * offset + 2) |> DateTime.new!(Time.new!(12, i, 0), "Etc/UTC")
  end

  # Seeds `n` Done cards in week `offset`, titled "W<offset>-<i>", newest last.
  defp seed_week(done, monday, offset, n) do
    for i <- 1..n do
      insert(:card, stage: done, title: "W#{offset}-#{i}", done_at: done_at(monday, offset, i))
    end
  end

  # Scenario 1's data: 3 this week, 2 last week, 1 in weeks −3, −5, −7, −9 → 9 cards.
  defp seed_scenario_one(done, monday) do
    seed_week(done, monday, 0, 3)
    seed_week(done, monday, -1, 2)
    for offset <- [-3, -5, -7, -9], do: seed_week(done, monday, offset, 1)
    :ok
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp query(view, selector), do: view |> doc() |> LazyHTML.query(selector)

  defp texts(view, selector), do: view |> query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> squish()))

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  defp markers(view, col), do: query(view, "##{col}-cards .week-marker")

  defp marker_ids(view, col), do: view |> markers(col) |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))

  defp card_titles(view, col), do: texts(view, "##{col}-cards .board-card .card-title")

  # The children of the stream container in DOM order, as {:marker, id, text} | {:card, title}.
  defp stream_children(view, col) do
    view
    |> query("##{col}-cards > .week-marker, ##{col}-cards > .board-card")
    |> Enum.map(fn node ->
      if node |> LazyHTML.attribute("class") |> hd() |> String.contains?("week-marker") do
        {:marker, node |> LazyHTML.attribute("id") |> hd(), node |> LazyHTML.text() |> squish()}
      else
        {:card, node |> LazyHTML.query(".card-title") |> LazyHTML.text() |> squish()}
      end
    end)
  end

  defp marker_id(done, date), do: "stage_cards_#{done.id}-week-#{Date.to_iso8601(date)}"

  defp click_more(view, col), do: view |> element("##{col}-show-more-done") |> render_click()

  describe "opening week" do
    test "opens on This week with one marker, its cards, the button and the full header count",
         %{conn: conn, board: board, done: done, monday: monday, col: col} do
      seed_scenario_one(done, monday)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert marker_ids(view, col) == [marker_id(done, monday)]
      [text] = texts(view, "##{col}-cards .week-marker")
      %{range: range} = DoneWeeks.label(monday, DateTime.utc_now(), "Etc/UTC")
      assert text =~ "This week"
      assert text =~ range
      assert text =~ "3"

      assert Enum.sort(card_titles(view, col)) == ["W0-1", "W0-2", "W0-3"]
      assert texts(view, "##{col}-show-more-done") == ["Load 4 more weeks"]
      assert view |> texts("##{col} .stage-count") |> hd() == "9"
    end

    test "with nothing done this week it opens on Last week",
         %{conn: conn, board: board, done: done, monday: monday, col: col} do
      seed_week(done, monday, -1, 2)
      seed_week(done, monday, -3, 1)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert [text] = texts(view, "##{col}-cards .week-marker")
      assert text =~ "Last week"
      refute text =~ "This week"
      assert Enum.sort(card_titles(view, col)) == ["W-1-1", "W-1-2"]
    end
  end

  describe "Load 4 more weeks" do
    test "one click appends the next 4 non-empty weeks, each marker before its own cards",
         %{conn: conn, board: board, done: done, monday: monday, col: col} do
      seed_scenario_one(done, monday)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      click_more(view, col)

      expected_weeks = Enum.map([0, -1, -3, -5, -7], &Date.add(monday, 7 * &1))
      assert marker_ids(view, col) == Enum.map(expected_weeks, &marker_id(done, &1))

      [this, last | _older] = texts(view, "##{col}-cards .week-marker")
      assert this =~ "This week"
      assert last =~ "Last week"

      # Each marker's count equals the cards between it and the next marker.
      groups =
        view
        |> stream_children(col)
        |> Enum.chunk_while(
          nil,
          fn
            {:marker, _id, text}, nil -> {:cont, {text, 0}}
            {:marker, _id, text}, acc -> {:cont, acc, {text, 0}}
            {:card, _title}, {text, n} -> {:cont, {text, n + 1}}
          end,
          fn acc -> {:cont, acc, nil} end
        )

      assert Enum.map(groups, fn {_text, n} -> n end) == [3, 2, 1, 1, 1]

      for {text, n} <- groups do
        assert text |> String.split() |> List.last() == Integer.to_string(n)
      end

      refute "W-9-1" in card_titles(view, col)

      for empty <- [-2, -4, -6] do
        refute has_element?(view, "##{marker_id(done, Date.add(monday, 7 * empty))}")
      end

      assert has_element?(view, "##{col}-show-more-done")
    end

    test "a second click reaches the oldest week and swaps the button for the end note",
         %{conn: conn, board: board, done: done, monday: monday, col: col} do
      seed_scenario_one(done, monday)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      click_more(view, col)
      click_more(view, col)

      assert length(marker_ids(view, col)) == 6
      assert List.last(marker_ids(view, col)) == marker_id(done, Date.add(monday, -63))
      assert "W-9-1" in card_titles(view, col)
      refute has_element?(view, "##{col}-show-more-done")
      assert texts(view, "##{col}-done-end") == ["That's everything"]
      assert view |> query("##{col}-drop > ##{col}-cards + ##{col}-done-end") |> Enum.count() == 1
    end

    test "a single week shows the end note and no button",
         %{conn: conn, board: board, done: done, monday: monday, col: col} do
      seed_week(done, monday, 0, 2)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      refute has_element?(view, "##{col}-show-more-done")
      assert texts(view, "##{col}-done-end") == ["That's everything"]
    end

    test "an empty Done column shows no marker, no button and no note",
         %{conn: conn, board: board, col: col} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert view |> markers(col) |> Enum.count() == 0
      refute has_element?(view, "##{col}-show-more-done")
      refute has_element?(view, "##{col}-done-end")
    end
  end

  describe "Load more button placement (RLY-116)" do
    test "the button flows right after the card list inside the drop-zone wrapper",
         %{conn: conn, board: board, done: done, monday: monday, col: col} do
      seed_scenario_one(done, monday)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      # the wrapper (not the stream list) carries the drop-zone contract
      assert view |> query("##{col}-drop.stage-drop[data-stage-id]") |> Enum.count() == 1
      assert view |> query("##{col}-cards[data-stage-id]") |> Enum.count() == 0

      # the button directly follows the stream list inside the wrapper, never inside it
      assert view |> query("##{col}-drop > ##{col}-cards + ##{col}-show-more-done") |> Enum.count() == 1
      assert view |> query("##{col}-cards ##{col}-show-more-done") |> Enum.count() == 0
    end
  end

  describe "realtime" do
    test "a card moved into Done lands under This week and keeps every revealed week",
         %{conn: conn, board: board, done: done, code: code, monday: monday, col: col} do
      seed_scenario_one(done, monday)
      {:ok, mover} = Cards.create_card(code, %{title: "Fresh finish"})
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      click_more(view, col)

      {:ok, _moved} = Cards.move_card(mover, done, 0, :agent)

      assert [{:marker, _id, this}, {:card, "Fresh finish"} | _rest] = stream_children(view, col)
      assert this =~ "This week"
      assert this |> String.split() |> List.last() == "4"
      assert length(marker_ids(view, col)) == 5
    end

    test "a card moved into a column open on Last week adds a This week marker above it",
         %{conn: conn, board: board, done: done, code: code, monday: monday, col: col} do
      seed_week(done, monday, -1, 2)
      {:ok, mover} = Cards.create_card(code, %{title: "Fresh finish"})
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      {:ok, _moved} = Cards.move_card(mover, done, 0, :agent)

      assert [this, last] = texts(view, "##{col}-cards .week-marker")
      assert this =~ "This week"
      assert last =~ "Last week"
      assert Enum.sort(card_titles(view, col)) == ["Fresh finish", "W-1-1", "W-1-2"]
    end

    test "moving out This week's only card drops its marker and re-anchors on Last week",
         %{conn: conn, board: board, done: done, code: code, monday: monday, col: col} do
      [only] = seed_week(done, monday, 0, 1)
      seed_week(done, monday, -1, 2)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      assert [_this] = texts(view, "##{col}-cards .week-marker")

      {:ok, _moved} = Cards.move_card(Repo.get!(Card, only.id), code, 0, :agent)

      assert [last] = texts(view, "##{col}-cards .week-marker")
      assert last =~ "Last week"
      assert Enum.sort(card_titles(view, col)) == ["W-1-1", "W-1-2"]
    end

    test "editing and commenting on an old card keeps it in its done week",
         %{conn: conn, board: board, done: done, monday: monday, col: col, user: user} do
      seed_week(done, monday, 0, 1)
      [old] = seed_week(done, monday, -3, 1)

      {:ok, _} = Cards.update_card(Repo.get!(Card, old.id), %{title: "Edited old"})
      {:ok, _} = Activity.add_comment(Repo.get!(Card, old.id), %{actor: {:user, user.id}, body: "late note"})

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      click_more(view, col)

      week_three = marker_id(done, Date.add(monday, -21))

      assert [_this_marker, {:card, "W0-1"}, {:marker, ^week_three, _text}, {:card, "Edited old"}] =
               stream_children(view, col)
    end
  end

  describe "RE389 — the open-card highlight respects the Done window" do
    test "opening a card from an unrevealed week by URL doesn't surface it",
         %{conn: conn, board: board, done: done, monday: monday, col: col} do
      seed_week(done, monday, 0, 1)
      [old] = seed_week(done, monday, -3, 1)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, old)}")

      assert card_titles(view, col) == ["W0-1"]
      refute has_element?(view, ".board-card[data-open]")

      render_patch(view, ~p"/board/#{board.slug}")

      assert card_titles(view, col) == ["W0-1"]
    end
  end

  describe "viewer time zone" do
    setup %{done: done, monday: monday} do
      # Monday 03:00 UTC a week back: Sunday evening in Los Angeles.
      utc_monday = Date.add(monday, -7)
      insert(:card, stage: done, title: "Sunday night", done_at: DateTime.new!(utc_monday, ~T[03:00:00], "Etc/UTC"))
      %{utc_monday: utc_monday}
    end

    test "Los Angeles buckets it in the previous week",
         %{conn: conn, board: board, done: done, col: col, utc_monday: utc_monday} do
      conn = put_connect_params(conn, %{"timezone" => "America/Los_Angeles"})
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert marker_ids(view, col) == [marker_id(done, Date.add(utc_monday, -7))]
    end

    for zone <- ["Etc/UTC", "Bogus/Zone"] do
      test "#{zone} buckets it in that Monday's week",
           %{conn: conn, board: board, done: done, col: col, utc_monday: utc_monday} do
        conn = put_connect_params(conn, %{"timezone" => unquote(zone)})
        {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

        assert marker_ids(view, col) == [marker_id(done, utc_monday)]
      end
    end
  end

  describe "scope" do
    test "a mid-board Done sub-lane gets no markers and no button",
         %{conn: conn, code: code, user: user} do
      {:ok, sub} = Boards.enable_lane(code, :done)
      for i <- 1..2, do: insert(:card, stage: sub, title: "Sub #{i}", done_at: DateTime.utc_now(:second))

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert view |> query("#sublane-#{sub.id}-cards .board-card") |> Enum.count() == 2
      refute has_element?(view, "#sublane-#{sub.id}-show-more-done")
      assert view |> query("#sublane-#{sub.id}-cards .week-marker") |> Enum.count() == 0
    end

    test "a non-terminal column has no button and no end note",
         %{conn: conn, board: board, code: code} do
      {:ok, _} = Cards.create_card(code, %{title: "Working"})
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      refute has_element?(view, "#stage-col-#{code.position}-show-more-done")
      refute has_element?(view, "#stage-col-#{code.position}-done-end")
    end
  end
end
