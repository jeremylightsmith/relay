defmodule RelayWeb.BoardSettingsLiveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.ApiKeys
  alias Relay.Boards
  alias RelayWeb.BoardSettingsLive
  alias Schemas.ApiKey

  describe "when logged out" do
    test "GET /board/:slug/settings redirects to the sign-in page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/board/anything/settings")
    end
  end

  describe "API key pane" do
    setup :register_and_log_in_user

    defp open_keys(conn, board) do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=keys")
      view
    end

    defp create_via_ui(view, name) do
      view |> element("#generate-key") |> render_click()
      view |> form("#new-key-form", new_key: %{name: name}) |> render_submit()
    end

    test "with no keys, only the Create button shows", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      view = open_keys(conn, board)

      assert has_element?(view, "#generate-key", "+ Create new key")
      refute has_element?(view, "#api-key-list [id^='api-key-']")
      refute has_element?(view, "#api-key-secret")
      refute has_element?(view, "#new-key-form")
    end

    test "Create opens an inline name form; Cancel closes it", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      view = open_keys(conn, board)

      view |> element("#generate-key") |> render_click()

      assert has_element?(view, "#new-key-form #new-key-name[placeholder='e.g. Mac mini']")
      assert has_element?(view, "#create-key-submit")
      refute has_element?(view, "#generate-key")

      view |> element("#cancel-new-key") |> render_click()

      refute has_element?(view, "#new-key-form")
      assert has_element?(view, "#generate-key")
      assert ApiKeys.list_keys(board) == []
    end

    test "creates a second named key while one exists; both are listed and Create stays", %{
      conn: conn,
      user: user
    } do
      board = Boards.get_or_create_default_board(user)
      {:ok, %{api_key: first}} = ApiKeys.create_key(board, user)
      view = open_keys(conn, board)

      create_via_ui(view, "Mac mini")

      assert [%{id: first_id}, second] = ApiKeys.list_keys(board)
      assert first_id == first.id
      assert second.name == "Mac mini"
      assert has_element?(view, "#api-key-#{first.id}")
      assert has_element?(view, "#api-key-#{second.id}")
      assert has_element?(view, "#api-key-name-#{second.id}-input[value='Mac mini']")
      assert has_element?(view, "#generate-key")
      refute has_element?(view, "#new-key-form")
    end

    test "the new key's token is revealed once, inside its own card only", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, %{api_key: first}} = ApiKeys.create_key(board, user)
      view = open_keys(conn, board)

      create_via_ui(view, "Mac mini")
      [_first, second] = ApiKeys.list_keys(board)

      assert has_element?(view, "#api-key-#{second.id} #api-key-reveal #api-key-secret")
      assert has_element?(view, "#api-key-#{second.id} #copy-key")
      assert has_element?(view, "#api-key-#{second.id} #api-key-reveal-note")
      refute has_element?(view, "#api-key-#{first.id} #api-key-secret")

      secret = revealed_secret(view)
      assert secret =~ ~r/^relay_[0-9a-f]{12}_[0-9a-f]{64}$/
      assert {:ok, authed} = ApiKeys.authenticate(secret)
      assert authed.id == board.id

      # reload: every key shows only its masked token
      view = open_keys(conn, board)
      refute has_element?(view, "#api-key-secret")
      refute render(view) =~ secret
      masked = view |> element("#api-key-masked-#{second.id}") |> render()
      assert masked =~ second.token_prefix
      assert masked =~ second.last_four
    end

    test "a blank name falls back to Key N", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, _a} = ApiKeys.create_key(board, user)
      {:ok, _b} = ApiKeys.create_key(board, user)
      view = open_keys(conn, board)

      create_via_ui(view, "   ")

      assert [_a, _b, third] = ApiKeys.list_keys(board)
      assert third.name == "Key 3"
      assert has_element?(view, "#api-key-name-#{third.id}-input[value='Key 3']")
    end

    test "a too-long name re-renders the form with the error and creates nothing", %{
      conn: conn,
      user: user
    } do
      board = Boards.get_or_create_default_board(user)
      view = open_keys(conn, board)

      create_via_ui(view, String.duplicate("x", ApiKey.name_max_length() + 1))

      assert has_element?(view, "#new-key-form", "should be at most")
      assert ApiKeys.list_keys(board) == []
    end

    test "renames a key inline; the name persists and its token still works", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, %{api_key: key, token: token}} = ApiKeys.create_key(board, user)
      view = open_keys(conn, board)

      view
      |> form("#api-key-name-#{key.id}-form", api_key: %{name: "Laptop"})
      |> render_submit()

      assert ApiKeys.get_key!(board, key.id).name == "Laptop"
      view = open_keys(conn, board)
      assert has_element?(view, "#api-key-name-#{key.id}-input[value='Laptop']")
      assert {:ok, _board} = ApiKeys.authenticate(token)
    end

    test "a blank rename shows the error and keeps the old name", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, %{api_key: key}} = ApiKeys.create_key(board, user, "Keep")
      view = open_keys(conn, board)

      view
      |> form("#api-key-name-#{key.id}-form", api_key: %{name: "  "})
      |> render_submit()

      assert has_element?(view, "#api-key-name-#{key.id}-form", "can't be blank")
      assert ApiKeys.get_key!(board, key.id).name == "Keep"
    end

    test "regenerate replaces only the targeted key and reveals it in that card", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, %{api_key: a, token: old_a}} = ApiKeys.create_key(board, user, "A")
      {:ok, %{api_key: b, token: token_b}} = ApiKeys.create_key(board, user, "B")
      view = open_keys(conn, board)

      view |> element("#regenerate-key-#{a.id}") |> render_click()

      assert has_element?(view, "#api-key-#{a.id} #api-key-secret")
      refute has_element?(view, "#api-key-#{b.id} #api-key-secret")
      new_a = revealed_secret(view)
      refute new_a == old_a
      assert :error = ApiKeys.authenticate(old_a)
      assert {:ok, _board} = ApiKeys.authenticate(new_a)
      assert {:ok, _board} = ApiKeys.authenticate(token_b)
    end

    test "revoke removes only the targeted key; the other keeps working", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, %{api_key: a, token: token_a}} = ApiKeys.create_key(board, user, "A")
      {:ok, %{api_key: b, token: token_b}} = ApiKeys.create_key(board, user, "B")
      view = open_keys(conn, board)

      view |> element("#revoke-key-#{a.id}") |> render_click()

      refute has_element?(view, "#api-key-#{a.id}")
      assert has_element?(view, "#api-key-#{b.id}")
      assert has_element?(view, "#generate-key")
      assert Enum.map(ApiKeys.list_keys(board), & &1.id) == [b.id]
      assert :error = ApiKeys.authenticate(token_a)
      assert {:ok, _board} = ApiKeys.authenticate(token_b)
    end

    test "a forged id for another board's key is refused", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, _mine} = ApiKeys.create_key(board, user)
      {:ok, %{api_key: foreign, token: foreign_token}} = ApiKeys.create_key(Relay.Factory.insert(:board), user)
      view = open_keys(conn, board)

      # get_key!/2 raises inside the LiveView, crashing it — the foreign key is untouched
      Process.flag(:trap_exit, true)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(render_click(view, "revoke_key", %{"id" => foreign.id}))
      end)

      assert {:ok, _board} = ApiKeys.authenticate(foreign_token)
    end

    test "each card carries name, Regenerate, Revoke, masked token, created and last-used", %{
      conn: conn,
      user: user
    } do
      board = Boards.get_or_create_default_board(user)
      {:ok, %{api_key: key}} = ApiKeys.create_key(board, user)
      view = open_keys(conn, board)

      assert has_element?(view, "#api-key-name-#{key.id}-input[value='Key 1']")
      assert has_element?(view, "#regenerate-key-#{key.id}", "Regenerate")
      assert has_element?(view, "#revoke-key-#{key.id}", "Revoke")
      assert has_element?(view, "#api-key-masked-#{key.id}")
      assert has_element?(view, "#api-key-created-#{key.id}")
      assert has_element?(view, "#api-key-last-used-#{key.id}", "Never")
      assert has_element?(view, "#generate-key")
    end

    test "layout matches the Relay Board artboard (card, dashed Create below, no Reveal)", %{
      conn: conn,
      user: user
    } do
      board = Boards.get_or_create_default_board(user)
      {:ok, %{api_key: key}} = ApiKeys.create_key(board, user)
      view = open_keys(conn, board)

      # Relay Board.dc.html ~L537: card = 1px border, radius 12px, padding 16px 18px
      assert has_element?(
               view,
               "#api-key-#{key.id}[style*='border:1px solid var(--color-base-300);border-radius:12px;padding:16px 18px']"
             )

      # ~L552: dashed Create button sits below the list with margin-top:14px
      assert has_element?(view, "#generate-key[style*='margin-top:14px'][style*='1px dashed']")
      refute has_element?(view, "#api-key-list #generate-key")
      # tokens are hashed — there is no Reveal/Hide toggle
      refute render(view) =~ ~r/>\s*(Reveal|Hide)\s*</
    end

    test "an archived board refuses key mutations as read-only", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, %{api_key: key}} = ApiKeys.create_key(board, user)
      {:ok, _archived} = Boards.archive_board(board)
      view = open_keys(conn, board)

      render_click(view, "create_key", %{"new_key" => %{"name" => "Sneaky"}})
      assert render(view) =~ "archived (read-only)"

      render_click(view, "rename_key", %{"key_id" => key.id, "api_key" => %{"name" => "Sneaky"}})
      render_click(view, "revoke_key", %{"id" => key.id})
      render_click(view, "regenerate_key", %{"id" => key.id})

      assert [%{name: "Key 1"}] = ApiKeys.list_keys(board)
      refute has_element?(view, "#api-key-secret")
    end

    test "the board page links to settings", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#board-settings-link[href='/board/#{board.slug}/settings']")
    end
  end

  describe "stage sub-lanes" do
    setup %{conn: conn} do
      user = Relay.Factory.insert(:user)
      board = Boards.get_or_create_default_board(user)
      %{conn: Plug.Test.init_test_session(conn, user_id: user.id), board: board}
    end

    test "toggling Review on creates the child lane; off removes it", %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=stages")

      view |> element("#stage-#{code.id}-review-toggle") |> render_click()
      assert [%{type: :review}] = Boards.sublanes(code)

      view |> element("#stage-#{code.id}-review-toggle") |> render_click()
      assert Boards.sublanes(code) == []
    end

    test "toggling off a non-empty lane is blocked with a flash", %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, review} = Boards.enable_lane(code, :review)
      Relay.Factory.insert(:card, stage: review)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=stages")
      html = view |> element("#stage-#{code.id}-review-toggle") |> render_click()

      assert html =~ "still has cards"
      assert [%{type: :review}] = Boards.sublanes(code)
    end

    test "a blocked disable snaps the checkbox back to checked instead of leaving it visually off",
         %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, review} = Boards.enable_lane(code, :review)
      Relay.Factory.insert(:card, stage: review)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=stages")
      view |> element("#stage-#{code.id}-review-toggle") |> render_click()

      # The blocked toggle bumps a render nonce into the checkbox's id so
      # the client swaps in a fresh, correctly-checked element rather than
      # patching the one the browser already unchecked on click.
      refute has_element?(view, "#stage-#{code.id}-review-toggle")
      assert has_element?(view, "#stage-#{code.id}-review-toggle-1[checked]")
    end
  end

  describe "stages pane" do
    setup %{conn: conn} do
      user = Relay.Factory.insert(:user)
      board = Boards.get_or_create_default_board(user)
      %{conn: Plug.Test.init_test_session(conn, user_id: user.id), board: board}
    end

    test "the delete-stage × uses a dark error ink, not the flat mid-tone token",
         %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=stages")

      # L 0.55 brand ink on a tinted chip maps to the ink formula (error 80%, base-content),
      # not the flat mid-tone fill/border token — the flat token washes out contrast in light mode.
      assert has_element?(
               view,
               "#stage-#{code.id}-delete[style*='color:color-mix(in oklab, var(--color-error) 80%, var(--color-base-content))']"
             )
    end
  end

  describe "breadcrumb trail (RE334)" do
    setup :register_and_log_in_user

    test "reads Boards / <board> / Settings / <section>, every crumb a link",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=stages")

      assert has_element?(view, ~s(#top-bar-crumb-boards[href="/boards"]))
      assert has_element?(view, ~s(#top-bar-crumb-board[href="/board/#{board.slug}"]), board.name)

      assert has_element?(
               view,
               ~s(#top-bar-crumb-settings[href="/board/#{board.slug}/settings"]),
               "Settings"
             )

      refute has_element?(view, "#top-bar-crumb-stages")
      assert has_element?(view, "#settings-title", BoardSettingsLive.section_label(:stages))
      refute has_element?(view, "#settings-title", "Board settings")
    end

    test "the last crumb follows the section as the rail patches", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      assert has_element?(view, "#settings-title", BoardSettingsLive.section_label(:general))

      view |> element("#settings-nav-members") |> render_click()
      assert has_element?(view, "#settings-title", BoardSettingsLive.section_label(:members))

      view |> element("#settings-tab-keys") |> render_click()
      assert has_element?(view, "#settings-title", BoardSettingsLive.section_label(:keys))
    end

    test "the rail and tab strip label every section through section_label/1",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      for section <- [:general, :stages, :agents, :public, :members, :keys, :runners] do
        label = BoardSettingsLive.section_label(section)
        assert has_element?(view, "#settings-nav-#{section}", label)
        assert has_element?(view, "#settings-tab-#{section}", label)
      end
    end

    test "Agents sits between Stages and Public board in the rail and the tab strip",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=agents")

      expected = ["General", "Stages", "Agents", "Public board", "Members", "API keys"]
      assert BoardSettingsLive.section_label(:agents) == "Agents"
      assert has_element?(view, "#settings-title", "Agents")

      for nav <- ["#settings-rail", "#settings-tabs"] do
        labels =
          view
          |> element(nav)
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.query("a")
          |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
          |> Enum.take(6)

        assert labels == expected
      end
    end
  end

  describe "top bar" do
    setup :register_and_log_in_user

    test "the Done button navigates back to the board", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      refute has_element?(view, "#back-to-board")
      assert has_element?(view, ~s(#settings-done[href="/board/#{board.slug}"]))
      assert has_element?(view, "#top-bar-crumb-boards")
      # daisyUI's own primitive, not a hand-rolled bg-primary utility stack
      assert has_element?(view, "#settings-done.btn-primary")
      refute has_element?(view, "#settings-done.bg-primary")
    end

    test "the avatar dropdown has Sign out but no Archived cards", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      assert has_element?(view, "#account-menu #sign-out")
      assert has_element?(view, "#account-menu [data-phx-theme='dark']")
      refute has_element?(view, "#archived-cards-menu-item")
    end
  end

  describe "default section" do
    setup :register_and_log_in_user

    test "bare /settings opens the General pane, not Stages", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      assert has_element?(view, "#general-pane")
      refute has_element?(view, "#stages-pane")
      # the General rail link carries nav_style/1's active blue-tint
      assert has_element?(view, "#settings-nav-general[style*='var(--color-primary) 45%, var(--color-base-content)']")
      refute has_element?(view, "#settings-nav-stages[style*='var(--color-primary) 45%, var(--color-base-content)']")
    end

    test "the board-key rename warning uses a dark warning ink, not the flat mid-tone token",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      # L 0.55 brand ink on a tinted chip maps to the ink formula (warning 65%, base-content),
      # not the flat mid-tone fill/border token — the flat token washes out contrast in light mode.
      assert has_element?(
               view,
               "#board-key-warning[style*='color-mix(in oklab, var(--color-warning) 65%, var(--color-base-content))']"
             )
    end
  end

  describe "mobile tab strip" do
    setup :register_and_log_in_user

    test "renders a horizontal tab strip linking every settings section", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      assert has_element?(view, "#settings-tabs")
      assert has_element?(view, "#settings-tab-general[href='/board/#{board.slug}/settings']")
      assert has_element?(view, "#settings-tab-stages[href='/board/#{board.slug}/settings?section=stages']")
      assert has_element?(view, "#settings-tab-members[href='/board/#{board.slug}/settings?section=members']")
      assert has_element?(view, "#settings-tab-keys[href='/board/#{board.slug}/settings?section=keys']")
    end

    test "the tab matching the current section carries the active style", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, general, _html} = live(conn, ~p"/board/#{board.slug}/settings")
      assert has_element?(general, "#settings-tab-general[style*='var(--color-primary) 45%, var(--color-base-content)']")
      refute has_element?(general, "#settings-tab-stages[style*='var(--color-primary) 45%, var(--color-base-content)']")

      {:ok, stages, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=stages")
      assert has_element?(stages, "#settings-tab-stages[style*='var(--color-primary) 45%, var(--color-base-content)']")
      refute has_element?(stages, "#settings-tab-general[style*='var(--color-primary) 45%, var(--color-base-content)']")
    end

    test "rail and strip carry the responsive show/hide classes", %{conn: conn, user: user} do
      # The real show/hide is a CSS media query (drawer: = 720px) that render
      # tests can't exercise — both chrome variants are always in the DOM. We
      # assert the responsive utility classes instead.
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      rail = view |> element("#settings-rail") |> render()
      assert rail =~ ~s(class="hidden drawer:flex")

      tabs = view |> element("#settings-tabs") |> render()
      assert tabs =~ "drawer:hidden"

      container = view |> element("#board-settings") |> render()
      assert container =~ "flex flex-col drawer:flex-row"
    end
  end

  defp revealed_secret(view) do
    view
    |> element("#api-key-secret")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  describe "set_reject_to board scoping (RE344)" do
    setup %{conn: conn} do
      user = Relay.Factory.insert(:user)
      board = Boards.get_or_create_default_board(user)
      %{conn: Plug.Test.init_test_session(conn, user_id: user.id), board: board}
    end

    test "a foreign stage id leaves the view alive and the stored reject_to unchanged",
         %{conn: conn, board: board} do
      review = Enum.find(board.stages, &(&1.name == "Review"))
      foreign = Relay.Factory.insert(:stage, board: Relay.Factory.insert(:board), name: "Elsewhere")
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=stages")

      render_click(view, "set_reject_to", %{"stage-id" => "#{review.id}", "target-id" => "#{foreign.id}"})

      assert Process.alive?(view.pid)
      assert Relay.Repo.get!(Schemas.Stage, review.id).reject_to_stage_id == review.reject_to_stage_id
    end

    test "a non-integer target id is ignored", %{conn: conn, board: board} do
      review = Enum.find(board.stages, &(&1.name == "Review"))
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=stages")

      render_click(view, "set_reject_to", %{"stage-id" => "#{review.id}", "target-id" => "abc"})

      assert Process.alive?(view.pid)
      assert Relay.Repo.get!(Schemas.Stage, review.id).reject_to_stage_id == review.reject_to_stage_id
    end

    test "a same-board main stage still persists", %{conn: conn, board: board} do
      review = Enum.find(board.stages, &(&1.name == "Review"))
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=stages")

      render_click(view, "set_reject_to", %{"stage-id" => "#{review.id}", "target-id" => "#{code.id}"})

      assert Relay.Repo.get!(Schemas.Stage, review.id).reject_to_stage_id == code.id
    end
  end
end
