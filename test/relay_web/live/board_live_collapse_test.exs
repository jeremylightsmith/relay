defmodule RelayWeb.BoardLiveCollapseTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    %{board: board, code: Enum.find(board.stages, &(&1.name == "Code"))}
  end

  describe "sub-lane collapse toggle (item 2)" do
    test "clicking a non-empty sub-lane header collapses it, and the strip re-expands it",
         %{conn: conn, code: code, user: user} do
      {:ok, done} = Boards.enable_lane(code, :done)
      {:ok, card} = Cards.create_card(code, %{title: "Shipit"})
      {:ok, _moved} = Cards.move_card(card, done, 0)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      # non-empty → renders expanded (cards container), not the strip
      assert has_element?(view, "#sublane-#{done.id}-cards")
      refute has_element?(view, "#sublane-#{done.id}-strip")

      view |> element("#sublane-#{done.id}-header") |> render_click()
      assert has_element?(view, "#sublane-#{done.id}-strip")

      view |> element("#sublane-#{done.id}-strip") |> render_click()
      assert has_element?(view, "#sublane-#{done.id}-cards")
      refute has_element?(view, "#sublane-#{done.id}-strip")
    end
  end

  describe "main lane collapse toggle (item 3)" do
    test "clicking the In progress header collapses the main lane to a strip, and back",
         %{conn: conn, code: code, user: user} do
      {:ok, _done} = Boards.enable_lane(code, :done)
      {:ok, _card} = Cards.create_card(code, %{title: "WIP"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-col-5-main-lane-header")
      refute has_element?(view, "#stage-col-5-main-strip")

      view |> element("#stage-col-5-main-lane-header") |> render_click()
      assert has_element?(view, "#stage-col-5-main-strip")

      view |> element("#stage-col-5-main-strip") |> render_click()
      refute has_element?(view, "#stage-col-5-main-strip")
      assert has_element?(view, "#stage-col-5-main-lane-header")
    end
  end

  describe "collapsed-by-default stages (RLY-111)" do
    test "a flagged stage with cards renders as the strip with its non-zero count",
         %{conn: conn, code: code, user: user} do
      {:ok, _} = Boards.update_stage(code, %{collapsed_by_default: true})
      {:ok, _} = Cards.create_card(code, %{title: "One"})
      {:ok, _} = Cards.create_card(code, %{title: "Two"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-strip-#{code.id} .stage-count", "2")
      refute has_element?(view, "#stage-col-5")
    end

    test "clicking the strip expands it, and the header control re-collapses it",
         %{conn: conn, code: code, user: user} do
      {:ok, _} = Boards.update_stage(code, %{collapsed_by_default: true})
      {:ok, _} = Cards.create_card(code, %{title: "Held"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view |> element("#stage-strip-#{code.id}") |> render_click()
      assert has_element?(view, "#stage-col-5")
      assert has_element?(view, "#stage-col-5-collapse")
      refute has_element?(view, "#stage-strip-#{code.id}")

      view |> element("#stage-col-5-collapse") |> render_click()
      assert has_element?(view, "#stage-strip-#{code.id} .stage-count", "1")
      refute has_element?(view, "#stage-col-5")
    end

    test "expansion is session-only — a fresh mount re-collapses",
         %{conn: conn, code: code, user: user} do
      {:ok, _} = Boards.update_stage(code, %{collapsed_by_default: true})
      {:ok, _} = Cards.create_card(code, %{title: "Held"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      view |> element("#stage-strip-#{code.id}") |> render_click()
      assert has_element?(view, "#stage-col-5")

      {:ok, fresh, _html} = live(conn, ~p"/board/#{board.slug}")
      assert has_element?(fresh, "#stage-strip-#{code.id}")
      refute has_element?(fresh, "#stage-col-5")
    end

    test "the collapse control does not render on a normal stage",
         %{conn: conn, code: code, user: user} do
      {:ok, _} = Cards.create_card(code, %{title: "Plain"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-col-5")
      refute has_element?(view, "#stage-col-5-collapse")
    end

    test "dropping a card onto the strip moves it in without expanding the stage",
         %{conn: conn, board: board, code: code, user: user} do
      backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
      {:ok, _} = Boards.update_stage(code, %{collapsed_by_default: true})
      {:ok, _} = Cards.create_card(code, %{title: "Already here"})
      {:ok, _} = Cards.create_card(backlog, %{title: "Incoming"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      assert has_element?(view, "#stage-strip-#{code.id} .stage-count", "1")

      render_hook(view, "move_card", %{"ref" => "RLY-2", "stage_id" => code.id, "index" => 0})

      assert has_element?(view, "#stage-strip-#{code.id} .stage-count", "2")
      refute has_element?(view, "#stage-col-5")
    end

    test "no regression: a normal non-empty stage stays expanded and an empty one still auto-collapses",
         %{conn: conn, board: board, code: code, user: user} do
      backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
      {:ok, _} = Cards.create_card(code, %{title: "Busy"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-col-5")
      refute has_element?(view, "#stage-strip-#{code.id}")
      # Backlog holds no cards, so the count-driven collapse still applies.
      assert has_element?(view, "#stage-strip-#{backlog.id} .stage-count", "0")
    end
  end
end
