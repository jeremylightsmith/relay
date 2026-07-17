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

    test "clicking the strip expands it, and the stage name re-collapses it",
         %{conn: conn, code: code, user: user} do
      {:ok, _} = Boards.update_stage(code, %{collapsed_by_default: true})
      {:ok, _} = Cards.create_card(code, %{title: "Held"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view |> element("#stage-strip-#{code.id}") |> render_click()
      assert has_element?(view, "#stage-col-5")
      assert has_element?(view, "#stage-col-5-name")
      refute has_element?(view, "#stage-strip-#{code.id}")

      view |> element("#stage-col-5-name") |> render_click()
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

    test "clicking any stage's name collapses it to the strip (RLY-145)",
         %{conn: conn, code: code, user: user} do
      {:ok, _} = Cards.create_card(code, %{title: "Plain"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-col-5")
      refute has_element?(view, "#stage-strip-#{code.id}")

      view |> element("#stage-col-5-name") |> render_click()
      assert has_element?(view, "#stage-strip-#{code.id} .stage-count", "1")
      refute has_element?(view, "#stage-col-5")
    end

    test "a name-click collapse is session-only — reload restores the expanded stage with its cards",
         %{conn: conn, code: code, user: user} do
      {:ok, _} = Cards.create_card(code, %{title: "Sticky"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      view |> element("#stage-col-5-name") |> render_click()
      assert has_element?(view, "#stage-strip-#{code.id}")

      {:ok, fresh, _html} = live(conn, ~p"/board/#{board.slug}")
      assert has_element?(fresh, "#stage-col-5")
      assert has_element?(fresh, "#stage-col-5-cards .board-card .card-title", "Sticky")
      refute has_element?(fresh, "#stage-strip-#{code.id}")
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

  describe "restream on expand (RLY-145)" do
    test "a collapsed-by-default stage shows its cards on first expand",
         %{conn: conn, code: code, user: user} do
      {:ok, _} = Boards.update_stage(code, %{collapsed_by_default: true})
      {:ok, _} = Cards.create_card(code, %{title: "Hidden treasure"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view |> element("#stage-strip-#{code.id}") |> render_click()

      assert has_element?(view, "#stage-col-5-cards .board-card .card-title", "Hidden treasure")
    end

    test "a card moved into a collapsed stage appears when the stage is expanded",
         %{conn: conn, board: board, code: code, user: user} do
      backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
      {:ok, _} = Boards.update_stage(code, %{collapsed_by_default: true})
      {:ok, incoming} = Cards.create_card(backlog, %{title: "Incoming"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      assert has_element?(view, "#stage-strip-#{code.id}")

      render_hook(view, "move_card", %{
        "ref" => Cards.ref(board, incoming),
        "stage_id" => code.id,
        "index" => 0
      })

      assert has_element?(view, "#stage-strip-#{code.id} .stage-count", "1")

      view |> element("#stage-strip-#{code.id}") |> render_click()
      assert has_element?(view, "#stage-col-5-cards .board-card .card-title", "Incoming")
    end

    test "expanding a manually collapsed sub-lane shows a card that landed while it was collapsed",
         %{conn: conn, code: code, user: user} do
      {:ok, done} = Boards.enable_lane(code, :done)
      {:ok, first} = Cards.create_card(code, %{title: "Shipped"})
      {:ok, _} = Cards.move_card(first, done, 0)
      {:ok, second} = Cards.create_card(code, %{title: "Also shipped"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      # user collapses the non-empty Done sub-lane…
      view |> element("#sublane-#{done.id}-header") |> render_click()
      assert has_element?(view, "#sublane-#{done.id}-strip")

      # …a card lands in it while collapsed (its restream targets a hidden container)…
      render_hook(view, "move_card", %{
        "ref" => Cards.ref(board, second),
        "stage_id" => done.id,
        "index" => 0
      })

      assert has_element?(view, "#sublane-#{done.id}-strip .sublane-strip-count", "2")

      # …expanding must show BOTH cards, not an empty lane
      view |> element("#sublane-#{done.id}-strip") |> render_click()
      assert has_element?(view, "#sublane-#{done.id}-cards .board-card .card-title", "Shipped")
      assert has_element?(view, "#sublane-#{done.id}-cards .board-card .card-title", "Also shipped")
    end

    test "collapsing a stage by name and re-expanding restores its cards",
         %{conn: conn, code: code, user: user} do
      {:ok, _} = Cards.create_card(code, %{title: "Keeper"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      assert has_element?(view, "#stage-col-5-cards .board-card .card-title", "Keeper")

      view |> element("#stage-col-5-name") |> render_click()
      assert has_element?(view, "#stage-strip-#{code.id}")

      view |> element("#stage-strip-#{code.id}") |> render_click()
      assert has_element?(view, "#stage-col-5-cards .board-card .card-title", "Keeper")
    end

    test "expanding a manually collapsed In progress lane shows a card that landed while it was collapsed",
         %{conn: conn, board: board, code: code, user: user} do
      # anchor a card in the Done sub-lane so the stage itself stays expanded
      # (an all-empty stage auto-collapses to its strip, hiding the lane header)
      {:ok, done} = Boards.enable_lane(code, :done)
      {:ok, anchor} = Cards.create_card(code, %{title: "Anchor"})
      {:ok, _} = Cards.move_card(anchor, done, 0)
      backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
      {:ok, incoming} = Cards.create_card(backlog, %{title: "Incoming"})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view |> element("#stage-col-5-main-lane-header") |> render_click()
      assert has_element?(view, "#stage-col-5-main-strip")

      render_hook(view, "move_card", %{
        "ref" => Cards.ref(board, incoming),
        "stage_id" => code.id,
        "index" => 0
      })

      view |> element("#stage-col-5-main-strip") |> render_click()
      assert has_element?(view, "#stage-col-5-cards .board-card .card-title", "Incoming")
    end

    test "expanding the Done stage still respects the done_revealed window",
         %{conn: conn, board: board, user: user} do
      done = Boards.terminal_stage(board.stages)

      for i <- 1..12 do
        insert(:card,
          stage: done,
          title: "Done #{i}",
          updated_at: DateTime.add(~U[2026-07-01 00:00:00Z], i, :second)
        )
      end

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      # collapse the terminal stage by clicking its name (Task 1), then expand its strip
      view |> element("#stage-col-#{done.position}-name") |> render_click()
      assert has_element?(view, "#stage-strip-#{done.id}")

      view |> element("#stage-strip-#{done.id}") |> render_click()

      titles =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#stage-col-#{done.position}-cards .board-card .card-title")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert length(titles) == 8
      assert "Done 12" in titles
      refute "Done 4" in titles
    end
  end
end
