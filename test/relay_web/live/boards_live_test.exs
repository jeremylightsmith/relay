defmodule RelayWeb.BoardsLiveTest do
  use RelayWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Repo
  alias Schemas.Board
  alias Schemas.Membership

  describe "when logged out" do
    test "GET /boards redirects to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/boards")
    end
  end

  describe "when logged in" do
    setup :register_and_log_in_user

    test "lists the user's active boards as cards", %{conn: conn, user: user} do
      first = Boards.get_or_create_default_board(user)
      {:ok, second} = Boards.create_board(user, %{name: "Launch"})

      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, "#board-card-#{first.slug}")
      assert has_element?(view, "#board-card-#{second.slug}", "Launch")
    end

    test "does not list another user's boards", %{conn: conn, user: user} do
      _mine = Boards.get_or_create_default_board(user)
      other = Relay.Factory.insert(:user)
      {:ok, theirs} = Boards.create_board(other, %{name: "Theirs"})

      {:ok, view, _html} = live(conn, ~p"/boards")

      refute has_element?(view, "#board-card-#{theirs.slug}")
    end

    test "badges the board named by ?from=<slug> as CURRENT", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/boards?from=#{board.slug}")

      assert has_element?(view, "#board-card-#{board.slug}-current", "CURRENT")
    end

    test "New board creates a board and navigates to its settings", %{conn: conn, user: user} do
      _default = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/boards")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#new-board-button") |> render_click()

      assert to =~ ~r{^/board/[a-z0-9-]+/settings$}
      assert Repo.aggregate(Board, :count) == 2
    end

    test "the top-bar + New board button creates a board and navigates to its settings",
         %{conn: conn, user: user} do
      _default = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/boards")

      {:error, {:live_redirect, %{to: to}}} =
        view |> element("#top-bar-new-board") |> render_click()

      assert to =~ ~r"^/board/.+/settings$"
    end

    test "the New board button uses daisyUI's btn-primary primitive, not a hand-rolled fill",
         %{conn: conn, user: user} do
      _default = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, "#top-bar-new-board.btn-primary")
      refute has_element?(view, "#top-bar-new-board.bg-primary")
    end

    test "both New board buttons press to Creating… (RE394)", %{conn: conn, user: user} do
      _default = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/boards")

      for id <- ~w(top-bar-new-board new-board-button) do
        assert has_element?(view, "##{id}.pending-action[phx-click=new_board]")
        assert view |> element("##{id} .pending-idle") |> render() =~ "New board"
        assert view |> element("##{id} .pending-face") |> render() =~ "Creating…"
      end
    end

    test "a board tile shows its needs-you count", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      review = Enum.find(board.stages, &(&1.type == :review))
      Relay.Factory.insert(:card, board: board, stage: review, status: :in_review)

      {:ok, view, _html} = live(conn, ~p"/boards")
      assert has_element?(view, "#board-needs-you-#{board.slug}")
    end

    test "no needs-you badge when nothing needs a human", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/boards")
      refute has_element?(view, "#board-needs-you-#{board.slug}")
    end
  end

  # RE395: a personal star at the end of each tile's name row — a sibling of the tile's
  # link (never inside the <a>) that toggles the star and reorders the grid in place.
  describe "starring" do
    setup :register_and_log_in_user

    setup %{user: user} do
      {:ok, zeta} = Boards.create_board(user, %{name: "zeta"})
      {:ok, alpha} = Boards.create_board(user, %{name: "Alpha"})
      {:ok, mango} = Boards.create_board(user, %{name: "mango"})
      %{zeta: zeta, alpha: alpha, mango: mango}
    end

    test "tiles render starred-first A–Z with New board last", %{conn: conn} = ctx do
      {:ok, _view, html} = live(conn, ~p"/boards")

      assert tile_order(html, ctx) == [:alpha, :mango, :zeta, :new]
    end

    test "an unstarred tile's star is a muted outline 'Star board' button", %{conn: conn, zeta: zeta} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      selector = ~s(#board-star-#{zeta.slug}[aria-pressed="false"][aria-label="Star board"])
      assert has_element?(view, selector)
      assert has_element?(view, ~s(#{selector}[type="button"][title="Star board"]))
      assert has_element?(view, ~s(#{selector}[phx-click="toggle_star"][phx-value-slug="#{zeta.slug}"]))

      button = view |> element("#board-star-#{zeta.slug}") |> render()
      assert "text-base-content/40" in classes(button)
      assert "hover:text-base-content" in classes(button)
      assert "btn btn-ghost btn-square btn-sm -my-1.5 -mr-1.5" in [button_base(button)]
      assert button =~ "hero-star "
      refute button =~ "hero-star-solid"
      assert button =~ "size-[18px]"
    end

    test "clicking the star stars the board in place and moves it to the front",
         %{conn: conn, user: user, zeta: zeta} = ctx do
      {:ok, view, _html} = live(conn, ~p"/boards")

      html = view |> element("#board-star-#{zeta.slug}") |> render_click()
      assert is_binary(html)

      assert tile_order(html, ctx) == [:zeta, :alpha, :mango, :new]

      selector = ~s(#board-star-#{zeta.slug}[aria-pressed="true"][aria-label="Unstar board"])
      assert has_element?(view, ~s(#{selector}[title="Unstar board"]))

      button = view |> element("#board-star-#{zeta.slug}") |> render()
      assert "text-base-content" in classes(button)
      refute "text-base-content/40" in classes(button)
      assert button =~ "hero-star-solid"

      assert %{starred?: true} =
               user |> Boards.list_boards_for_display() |> Enum.find(&(&1.board.id == zeta.id))
    end

    test "clicking a starred board's star unstars it and restores A–Z", %{conn: conn, zeta: zeta} = ctx do
      {:ok, view, _html} = live(conn, ~p"/boards")
      view |> element("#board-star-#{zeta.slug}") |> render_click()

      html = view |> element("#board-star-#{zeta.slug}") |> render_click()

      assert tile_order(html, ctx) == [:alpha, :mango, :zeta, :new]
      assert has_element?(view, ~s(#board-star-#{zeta.slug}[aria-pressed="false"]))
    end

    test "starring a board the user just lost reloads silently", %{conn: conn, user: user, mango: mango} do
      {:ok, view, _html} = live(conn, ~p"/boards")
      assert has_element?(view, "#board-card-#{mango.slug}")

      Repo.delete_all(from m in Membership, where: m.user_id == ^user.id and m.board_id == ^mango.id)

      render_hook(view, "toggle_star", %{"slug" => mango.slug})

      refute has_element?(view, "#board-card-#{mango.slug}")
      refute has_element?(view, "#flash-error")
      refute has_element?(view, "#flash-info")
    end

    test "a star is personal — another member's order is unchanged",
         %{conn: conn, mango: mango, zeta: zeta} do
      other = Relay.Factory.insert(:user)
      Relay.Factory.insert(:membership, board: mango, user: other, email: other.email)
      Relay.Factory.insert(:membership, board: zeta, user: other, email: other.email)

      {:ok, view, _html} = live(conn, ~p"/boards")
      view |> element("#board-star-#{zeta.slug}") |> render_click()

      {:ok, other_view, other_html} = live(log_in_user(build_conn(), other), ~p"/boards")

      assert index_of(other_html, "board-card-#{mango.slug}") <
               index_of(other_html, "board-card-#{zeta.slug}")

      assert has_element?(other_view, ~s(#board-star-#{zeta.slug}[aria-pressed="false"]))
    end

    test "the star is a sibling of the tile link, not inside it", %{conn: conn, alpha: alpha} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, "#board-star-#{alpha.slug}")
      refute has_element?(view, "a #board-star-#{alpha.slug}")
      assert has_element?(view, "#board-card-#{alpha.slug} a[href='/board/#{alpha.slug}']")
    end

    test "the star comes after the CURRENT badge in the name row", %{conn: conn, alpha: alpha} do
      {:ok, view, _html} = live(conn, ~p"/boards?from=#{alpha.slug}")

      tile = view |> element("#board-card-#{alpha.slug}") |> render()

      assert index_of(tile, "board-card-#{alpha.slug}-current") <
               index_of(tile, "board-star-#{alpha.slug}")
    end
  end

  defp tile_order(html, ctx) do
    [
      alpha: "board-card-#{ctx.alpha.slug}\"",
      mango: "board-card-#{ctx.mango.slug}\"",
      zeta: "board-card-#{ctx.zeta.slug}\"",
      new: "new-board-button"
    ]
    |> Enum.map(fn {key, needle} -> {key, index_of(html, needle)} end)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  defp index_of(html, needle) do
    case :binary.match(html, needle) do
      {pos, _len} -> pos
      :nomatch -> flunk("#{inspect(needle)} not found in rendered HTML")
    end
  end

  defp classes(button_html) do
    [_, class] = Regex.run(~r/<button[^>]*\sclass="([^"]*)"/, button_html)
    String.split(class)
  end

  defp button_base(button_html) do
    button_html |> classes() |> Enum.take(6) |> Enum.join(" ")
  end
end
