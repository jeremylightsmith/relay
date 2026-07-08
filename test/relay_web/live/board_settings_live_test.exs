defmodule RelayWeb.BoardSettingsLiveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.ApiKeys
  alias Relay.Boards

  describe "when logged out" do
    test "GET /board/settings redirects to the sign-in page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/board/settings")
    end
  end

  describe "API key pane" do
    setup :register_and_log_in_user

    test "with no key, offers Generate and shows no secret or details", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board/settings")

      assert has_element?(view, "#generate-key")
      refute has_element?(view, "#api-key-secret")
      refute has_element?(view, "#api-key-details")
    end

    test "generate reveals the full secret once, with copy button and warning", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/board/settings")

      view |> element("#generate-key") |> render_click()

      secret = revealed_secret(view)
      assert secret =~ ~r/^relay_[0-9a-f]{12}_[0-9a-f]{64}$/
      assert has_element?(view, "#copy-key")
      assert has_element?(view, "#api-key-reveal-note")
      refute has_element?(view, "#generate-key")

      # the revealed token is the real key — it authenticates against this board
      board = Boards.get_or_create_default_board(user)
      assert {:ok, authed_board} = ApiKeys.authenticate(secret)
      assert authed_board.id == board.id
    end

    test "on reload only the masked display shows — never the raw secret", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/board/settings")
      view |> element("#generate-key") |> render_click()
      secret = revealed_secret(view)

      {:ok, view, _html} = live(conn, ~p"/board/settings")

      refute has_element?(view, "#api-key-secret")
      refute render(view) =~ secret

      key = user |> Boards.get_or_create_default_board() |> ApiKeys.get_key()
      masked = view |> element("#api-key-masked") |> render()
      assert masked =~ key.token_prefix
      assert masked =~ key.last_four
    end

    test "shows name, masked value, created, and last-used; no second Generate", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, _created} = ApiKeys.create_key(board, user)

      {:ok, view, _html} = live(conn, ~p"/board/settings")

      assert has_element?(view, "#api-key-name", "Board API key")
      assert has_element?(view, "#api-key-masked")
      assert has_element?(view, "#api-key-created")
      assert has_element?(view, "#api-key-last-used", "Never")
      assert has_element?(view, "#regenerate-key")
      assert has_element?(view, "#revoke-key")
      refute has_element?(view, "#generate-key")
    end

    test "regenerate reveals a new secret once and invalidates the old one", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, %{token: old_token}} = ApiKeys.create_key(board, user)

      {:ok, view, _html} = live(conn, ~p"/board/settings")
      view |> element("#regenerate-key") |> render_click()

      new_secret = revealed_secret(view)
      assert new_secret =~ ~r/^relay_[0-9a-f]{12}_[0-9a-f]{64}$/
      refute new_secret == old_token
      assert :error = ApiKeys.authenticate(old_token)
      assert {:ok, _board} = ApiKeys.authenticate(new_secret)

      # reveal is once: a fresh mount shows only the masked display
      {:ok, view, _html} = live(conn, ~p"/board/settings")
      refute has_element?(view, "#api-key-secret")
    end

    test "revoke removes the key and offers Generate again", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, %{token: token}} = ApiKeys.create_key(board, user)

      {:ok, view, _html} = live(conn, ~p"/board/settings")
      view |> element("#revoke-key") |> render_click()

      assert has_element?(view, "#generate-key")
      refute has_element?(view, "#api-key-details")
      assert ApiKeys.get_key(board) == nil
      assert :error = ApiKeys.authenticate(token)
    end

    test "the board page links to settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#board-settings-link[href='/board/settings']")
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
      {:ok, view, _html} = live(conn, ~p"/board/settings")

      view |> element("#stage-#{code.id}-review-toggle") |> render_click()
      assert [%{lane: :review}] = Boards.sublanes(code)

      view |> element("#stage-#{code.id}-review-toggle") |> render_click()
      assert Boards.sublanes(code) == []
    end

    test "toggling off a non-empty lane is blocked with a flash", %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, review} = Boards.enable_lane(code, :review)
      Relay.Factory.insert(:card, stage: review)

      {:ok, view, _html} = live(conn, ~p"/board/settings")
      html = view |> element("#stage-#{code.id}-review-toggle") |> render_click()

      assert html =~ "still has cards"
      assert [%{lane: :review}] = Boards.sublanes(code)
    end

    test "a blocked disable snaps the checkbox back to checked instead of leaving it visually off",
         %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, review} = Boards.enable_lane(code, :review)
      Relay.Factory.insert(:card, stage: review)

      {:ok, view, _html} = live(conn, ~p"/board/settings")
      view |> element("#stage-#{code.id}-review-toggle") |> render_click()

      # The blocked toggle bumps a render nonce into the checkbox's id so
      # the client swaps in a fresh, correctly-checked element rather than
      # patching the one the browser already unchecked on click.
      refute has_element?(view, "#stage-#{code.id}-review-toggle")
      assert has_element?(view, "#stage-#{code.id}-review-toggle-1[checked]")
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
end
