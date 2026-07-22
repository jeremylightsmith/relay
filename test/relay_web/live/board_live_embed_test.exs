defmodule RelayWeb.BoardLiveEmbedTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

  describe "embedded board (?embed=1)" do
    setup :register_and_log_in_user

    test "suppresses the top-bar header while keeping the board content", %{
      conn: conn,
      user: user
    } do
      board = Boards.get_or_create_default_board(user)

      # Dead render: the header is already gone before the socket connects, so
      # there is no header flash under the native AppBar.
      html = conn |> get(~p"/board/#{board.slug}?embed=1") |> html_response(200)
      refute html =~ ~s(id="top-bar")

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

      refute has_element?(view, "#top-bar")
      assert has_element?(view, "#board")
    end

    test "reclaims the 53px — the viewport is full-height", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

      viewport = view |> element("#board-viewport") |> render()

      assert viewport =~ "h-dvh"
      refute viewport =~ "min-h-dvh"
      refute viewport =~ "calc(100dvh_-_53px)"
    end
  end

  describe "non-embedded board (default)" do
    setup :register_and_log_in_user

    test "renders the top-bar header and the 53px-offset viewport", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#top-bar")

      viewport = view |> element("#board-viewport") |> render()

      assert viewport =~ "h-[calc(100dvh_-_53px)]"
      refute viewport =~ "min-h-[calc(100dvh_-_53px)]"
      refute viewport =~ "h-dvh"
    end
  end

  describe "embedded boards list (?embed=1)" do
    setup :register_and_log_in_user

    test "suppresses the top-bar header while keeping the boards grid", %{
      conn: conn,
      user: user
    } do
      _board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/boards?embed=1")

      refute has_element?(view, "#top-bar")
      assert has_element?(view, "#boards-home")
    end

    test "default (no flag) renders the top-bar header", %{conn: conn, user: user} do
      _board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, "#top-bar")
    end
  end

  describe "embedded card drawer (?card=&embed=1)" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      review = Enum.find(board.stages, &(&1.name == "Review"))
      {:ok, card} = Cards.create_card(review, %{title: "Review me"})
      {:ok, _card} = Cards.set_status(card, %{status: :in_review})

      %{board: board, ref: Cards.ref(board, card)}
    end

    test "keeps the review context but drops the web actions", %{conn: conn, board: board, ref: ref} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}&embed=1")
      render_async(view)

      assert has_element?(view, "#review-panel", "READY FOR YOUR REVIEW")
      refute has_element?(view, "#review-approve")
      refute has_element?(view, "#review-request-changes")
      refute has_element?(view, "#card-drawer-scrim")
      refute has_element?(view, "#card-drawer-close")
    end

    test "the web board is unchanged — no embed, all actions present", %{
      conn: conn,
      board: board,
      ref: ref
    } do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
      render_async(view)

      assert has_element?(view, "#review-panel", "READY FOR YOUR REVIEW")
      assert has_element?(view, "#review-approve")
      assert has_element?(view, "#review-request-changes")
      assert has_element?(view, "#card-drawer-scrim")
      assert has_element?(view, "#card-drawer-close")
    end
  end

  describe "embed card-tap bridge (RLY-94)" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog | _rest] = board.stages
      {:ok, card} = Cards.create_card(backlog, %{title: "Tap me"})
      %{board: board, backlog: backlog, card: card}
    end

    test "selecting a card pushes card-tap to the shell instead of opening the drawer",
         %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

      view |> element(".board-card", "Tap me") |> render_click()

      slug = board.slug
      assert_push_event(view, "card-tap", %{ref: "MY1", board: ^slug, kind: nil})
      refute has_element?(view, "#card-drawer")
    end

    test "a review-gated card taps through with kind \"in_review\" for the native bar",
         %{conn: conn, board: board} do
      review = Enum.find(board.stages, &(&1.name == "Review"))
      {:ok, card} = Cards.create_card(review, %{title: "Judge me"})
      {:ok, _card} = Cards.set_status(card, %{"status" => "in_review"})
      ref = Cards.ref(board, card)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

      view |> element(".board-card", "Judge me") |> render_click()

      slug = board.slug
      assert_push_event(view, "card-tap", %{ref: ^ref, board: ^slug, kind: "in_review"})
    end

    test "a failed card taps through with kind \"failed\" for the native bar",
         %{conn: conn, board: board} do
      [backlog | _rest] = board.stages
      {:ok, card} = Cards.create_card(backlog, %{title: "Dead run"})
      {:ok, _card} = Cards.set_status(card, %{"status" => "failed"})
      ref = Cards.ref(board, card)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

      view |> element(".board-card", "Dead run") |> render_click()

      slug = board.slug
      assert_push_event(view, "card-tap", %{ref: ^ref, board: ^slug, kind: "failed"})
    end

    test "an archived-modal row tap bridges too", %{conn: conn, board: board, card: card, user: user} do
      {:ok, _archived} = Cards.archive_card(card, {:user, user.id})

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

      # The embed layout suppresses the top bar (and its Archived menu item), so
      # drive the handler directly — same pattern as the realtime tests' move_card.
      render_hook(view, "open_archived_card", %{"ref" => "MY1"})

      slug = board.slug
      assert_push_event(view, "card-tap", %{ref: "MY1", board: ^slug, kind: nil})
      refute has_element?(view, "#card-drawer")
    end

    test "the payload carries the tapped column's ordered refs, each with its own kind (RLY-234)",
         %{conn: conn, board: board, backlog: backlog} do
      _second = insert(:card, stage: backlog, title: "Second", position: 2, ref_number: 2)
      third = insert(:card, stage: backlog, title: "Third", position: 3, ref_number: 3)
      {:ok, _third} = Cards.set_status(third, %{"status" => "failed"})

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

      view |> element(".board-card", "Tap me") |> render_click()

      slug = board.slug

      assert_push_event(view, "card-tap", %{
        ref: "MY1",
        board: ^slug,
        kind: nil,
        column: [
          %{ref: "MY1", kind: nil},
          %{ref: "MY2", kind: nil},
          %{ref: "MY3", kind: "failed"}
        ]
      })
    end

    test "the column is the same full ordered list no matter which card in it was tapped",
         %{conn: conn, board: board, backlog: backlog} do
      _second = insert(:card, stage: backlog, title: "Second", position: 2, ref_number: 2)
      third = insert(:card, stage: backlog, title: "Third", position: 3, ref_number: 3)
      {:ok, _third} = Cards.set_status(third, %{"status" => "failed"})

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

      view |> element(".board-card", "Second") |> render_click()

      slug = board.slug

      assert_push_event(view, "card-tap", %{
        ref: "MY2",
        board: ^slug,
        kind: nil,
        column: [
          %{ref: "MY1", kind: nil},
          %{ref: "MY2", kind: nil},
          %{ref: "MY3", kind: "failed"}
        ]
      })
    end

    test "non-embed select still patches the drawer open (phone-width web keeps the drawer)",
         %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view |> element(".board-card", "Tap me") |> render_click()

      assert_patch(view, ~p"/board/#{board.slug}?card=MY1")
      assert has_element?(view, "#card-drawer")
    end
  end
end
