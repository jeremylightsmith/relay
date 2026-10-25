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
      {:ok, theirs} = Boards.create_board(other, %{name: "Theirs", slug: unique_slug("theirs")})

      {:ok, view, _html} = live(conn, ~p"/boards")

      refute has_element?(view, "#board-card-#{theirs.slug}")
    end

    test "badges the board named by ?from=<slug> as CURRENT", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/boards?from=#{board.slug}")

      assert has_element?(view, "#board-card-#{board.slug}-current", "CURRENT")
    end

    test "New board opens the template picker instead of creating a board (RE442)", %{conn: conn, user: user} do
      _default = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/boards")

      view |> element("#new-board-button") |> render_click()

      assert has_element?(view, "#template-picker")
      assert Repo.aggregate(Board, :count) == 1
    end

    test "the top-bar + New board button opens the template picker (RE442)",
         %{conn: conn, user: user} do
      _default = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/boards")

      view |> element("#top-bar-new-board") |> render_click()

      assert has_element?(view, "#template-picker")
      assert Repo.aggregate(Board, :count) == 1
    end

    test "the New board button uses daisyUI's btn-primary primitive, not a hand-rolled fill",
         %{conn: conn, user: user} do
      _default = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, "#top-bar-new-board.btn-primary")
      refute has_element?(view, "#top-bar-new-board.bg-primary")
    end

    test "both New board buttons open the picker, whose Create presses to Creating… (RE394, RE442)",
         %{conn: conn, user: user} do
      _default = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/boards")

      for id <- ~w(top-bar-new-board new-board-button) do
        assert has_element?(view, "##{id}[phx-click=open_template_picker]")
        refute has_element?(view, "##{id}.pending-action")
      end

      view |> element("#top-bar-new-board") |> render_click()

      assert has_element?(view, "#template-picker-create.pending-action")
      assert view |> element("#template-picker-create .pending-face") |> render() =~ "Creating…"
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
      {:ok, zeta} = Boards.create_board(user, %{name: "zeta", slug: unique_slug("zeta")})
      {:ok, alpha} = Boards.create_board(user, %{name: "Alpha", slug: unique_slug("alpha")})
      {:ok, mango} = Boards.create_board(user, %{name: "mango", slug: unique_slug("mango")})
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

    # RE406: mute is native-only — the web tiles keep the star and get no bell/mute control,
    # muted or not (the mute is enforced server-side).
    test "no mute control on web, muted or not", %{conn: conn, user: user, alpha: alpha, zeta: zeta} do
      {:ok, true} = Boards.set_muted(user, zeta.slug, true)

      {:ok, view, _html} = live(conn, ~p"/boards")

      # The top bar's browser-notifications control (RE399) carries its own hero-bell, so the
      # "no bell" check is scoped to the board tiles.
      for board <- [alpha, zeta] do
        assert has_element?(view, "#board-star-#{board.slug}")
        refute view |> element("#board-card-#{board.slug}") |> render() =~ "hero-bell"
      end

      refute has_element?(view, ~s([id^="board-mute"]))
      refute has_element?(view, ~s([phx-click="toggle_mute"]))
    end
  end

  # RE469 — the Free limit on the Boards page: the plan line and READ-ONLY tiles.
  describe "on Free" do
    setup :register_and_log_in_user

    setup do
      Process.put(:billing_enabled, true)
      %{today: Date.utc_today()}
    end

    # Owner F: live boards A, B and C, a card most recently updated on A (the editable board).
    defp owner_f!(user) do
      {:ok, a} = Boards.create_board(user, %{name: "Alpha", key: "AL", slug: unique_slug("alpha")})
      {:ok, b} = Boards.create_board(user, %{name: "Bravo", key: "BR", slug: unique_slug("bravo")})
      {:ok, c} = Boards.create_board(user, %{name: "Charlie", key: "CH", slug: unique_slug("charlie")})
      {:ok, card} = Relay.Cards.create_card(hd(a.stages), %{title: "Newest"})

      card
      |> Ecto.Changeset.change(updated_at: DateTime.utc_now() |> DateTime.add(60) |> DateTime.truncate(:second))
      |> Repo.update!()

      %{a: a, b: b, c: c}
    end

    defp squished_text(view, selector) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")
    end

    test "a new owner with one board sees the plan line at the limit (scenario 1)", %{conn: conn, user: user} do
      {:ok, _board} = Boards.create_board(user, %{name: "Only", key: "ON", slug: unique_slug("only")})
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, ~s(#boards-plan-line[href="/account/billing"]))
      assert has_element?(view, "#boards-plan-line .badge.badge-soft.badge-neutral.badge-sm", "Free")
      assert squished_text(view, "#boards-plan-line") =~ "1 of 1 boards · Upgrade"
      assert has_element?(view, "#boards-plan-line .link.link-primary", "Upgrade")
      refute has_element?(view, ~s([id^="board-card-"][id$="-read-only"]))
    end

    test "owner F sees the over-limit plan line and READ-ONLY tiles (scenario 2)", %{conn: conn, user: user} do
      %{a: a, b: b, c: c} = owner_f!(user)
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert squished_text(view, "#boards-plan-line") =~ "3 boards · 1 editable · Upgrade"

      for board <- [b, c] do
        assert has_element?(view, "#board-card-#{board.slug}-read-only", "READ-ONLY")
        assert has_element?(view, "#board-card-#{board.slug}.opacity-75")
      end

      refute has_element?(view, "#board-card-#{a.slug}-read-only")
      refute has_element?(view, "#board-card-#{a.slug}.opacity-75")
    end

    test "an active owner sees no plan line and no READ-ONLY label (scenario 3)", %{
      conn: conn,
      user: user,
      today: today
    } do
      owner_f!(user)
      insert(:billing_account, user: user, paid_through: Date.add(today, 30), billing_day: today.day)
      {:ok, view, _html} = live(conn, ~p"/boards")

      refute has_element?(view, "#boards-plan-line")
      refute has_element?(view, ~s([id^="board-card-"][id$="-read-only"]))
    end

    test "a comped owner sees no plan line and no READ-ONLY label (scenario 3)", %{conn: conn, user: user} do
      owner_f!(user)
      insert(:billing_account, user: user, comped: true)
      {:ok, view, _html} = live(conn, ~p"/boards")

      refute has_element?(view, "#boards-plan-line")
      refute has_element?(view, ~s([id^="board-card-"][id$="-read-only"]))
    end

    test "billing disabled: no plan line and no READ-ONLY label (scenario 3)", %{conn: conn, user: user} do
      owner_f!(user)
      Process.put(:billing_enabled, false)
      {:ok, view, _html} = live(conn, ~p"/boards")

      refute has_element?(view, "#boards-plan-line")
      refute has_element?(view, ~s([id^="board-card-"][id$="-read-only"]))
    end

    test "upgrading clears the plan line and labels without a reload (scenario 4)", %{
      conn: conn,
      user: user,
      today: today
    } do
      %{b: b} = owner_f!(user)
      {:ok, view, _html} = live(conn, ~p"/boards")
      assert has_element?(view, "#boards-plan-line")
      assert has_element?(view, "#board-card-#{b.slug}-read-only")

      insert(:billing_account, user: user, paid_through: Date.add(today, 30), billing_day: today.day)
      :ok = Relay.Billing.broadcast_changed(user.id)

      refute has_element?(view, "#boards-plan-line")
      refute has_element?(view, ~s([id^="board-card-"][id$="-read-only"]))
    end

    test "embedded in the app: no plan line, and the picker footer has no Upgrade link (scenario 5)", %{
      conn: conn,
      user: user
    } do
      {:ok, _board} = Boards.create_board(user, %{name: "Only", key: "ON", slug: unique_slug("only")})
      {:ok, view, _html} = live(conn, ~p"/boards?embed=1")

      refute has_element?(view, "#boards-plan-line")

      # The embedded render has no top bar; the New board tile is still there.
      view |> element("#new-board-button") |> render_click()

      assert has_element?(view, "#template-picker-upgrade", "Free includes one board.")
      assert has_element?(view, "#template-picker-upgrade", "Upgrade for unlimited boards, $20/mo.")
      assert has_element?(view, "#template-picker-cancel")
      refute has_element?(view, "#template-picker-upgrade-link")
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
