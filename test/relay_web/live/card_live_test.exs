defmodule RelayWeb.CardLiveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    review = Enum.find(board.stages, &(&1.name == "Review"))
    {:ok, card} = Cards.create_card(review, %{title: "Review me"})
    {:ok, card} = Cards.set_status(card, %{status: :in_review})

    %{board: board, card: card, ref: Cards.ref(board, card)}
  end

  # LiveViewTest has `refute_redirected/1` but no patch counterpart; a push_patch lands in the
  # test process as this message, so its absence is "no patch happened".
  defp refute_patched(%{proxy: {ref, topic, _}}), do: refute_received({^ref, {:patch, ^topic, _}})

  describe "/cards/:ref" do
    test "renders the card body with no board and no web chrome", %{conn: conn, board: board, ref: ref} do
      {:ok, view, _html} = live(conn, ~p"/cards/#{ref}?board=#{board.slug}")
      render_async(view)

      assert has_element?(view, "#card-drawer")
      refute has_element?(view, "#board-viewport")
      refute has_element?(view, "#top-bar")
    end

    test "the dead render is already chromeless — no header flash under the native bar", %{
      conn: conn,
      board: board,
      ref: ref
    } do
      html = conn |> get(~p"/cards/#{ref}?board=#{board.slug}") |> html_response(200)

      refute html =~ ~s(id="top-bar")
      refute html =~ ~s(id="board-viewport")
    end

    test "card mode is chromeless without ?embed=1 — the route implies it", %{
      conn: conn,
      board: board,
      ref: ref
    } do
      {:ok, view, _html} = live(conn, ~p"/cards/#{ref}?board=#{board.slug}")

      refute has_element?(view, "#top-bar")
    end

    test "keeps the review context but drops the web actions and dismissal", %{
      conn: conn,
      board: board,
      ref: ref
    } do
      {:ok, view, _html} = live(conn, ~p"/cards/#{ref}?board=#{board.slug}")
      render_async(view)

      # The context for the decision is the whole point of the screen.
      assert has_element?(view, "#review-panel", "READY FOR YOUR REVIEW")
      # The native bar is the only actor; the native back chevron owns dismissal.
      refute has_element?(view, "#review-approve")
      refute has_element?(view, "#review-request-changes")
      refute has_element?(view, "#card-drawer-scrim")
      refute has_element?(view, "#card-drawer-close")
    end

    test "approving stays on the card and updates in place (RLY-115)",
         %{conn: conn, board: board, ref: ref} do
      {:ok, view, _html} = live(conn, ~p"/cards/#{ref}?board=#{board.slug}")
      render_async(view)

      assert has_element?(view, "#review-panel", "READY FOR YOUR REVIEW")

      # Card mode drops the web review buttons (the native bar is the actor, RLY-87), so
      # push the event straight to the view — the handler is shared with board mode.
      render_click(view, "review_approve", %{})

      assert has_element?(view, "#card-drawer")
      refute has_element?(view, "#review-panel")
      assert has_element?(view, "#card-drawer .drawer-stage-chip", "Deploy")
      assert Cards.get_card_by_ref(board, ref).status == :working
    end

    test "approving in card mode never advances to the next card awaiting review (RE388)",
         %{conn: conn, board: board, ref: ref} do
      review = Enum.find(board.stages, &(&1.name == "Review"))
      {:ok, other} = Cards.create_card(review, %{title: "Other"})
      {:ok, _other} = Cards.set_status(other, %{status: :in_review})

      {:ok, view, _html} = live(conn, ~p"/cards/#{ref}?board=#{board.slug}")
      render_async(view)

      render_click(view, "review_approve", %{})

      refute_patched(view)
      assert has_element?(view, "#card-drawer .drawer-stage-chip", "Deploy")
      assert has_element?(view, "#card-drawer", "Review me")
      refute has_element?(view, "#card-drawer", "Other")
      refute has_element?(view, "#flash-info")
    end

    test "answering stays on the card and updates in place (RLY-115)",
         %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, card} = Cards.create_card(code, %{title: "Blocked native"})
      {:ok, _blocked} = Cards.request_input(card, "Which bucket?")
      ref = Cards.ref(board, card)

      {:ok, view, _html} = live(conn, ~p"/cards/#{ref}?board=#{board.slug}")
      render_async(view)

      assert has_element?(view, "#needs-input-panel", "Which bucket?")

      view
      |> form("#needs-input-form", answer: %{body: "The relay-exports bucket"})
      |> render_submit()

      assert has_element?(view, "#card-drawer")
      refute has_element?(view, "#needs-input-panel")
      assert Cards.get_card_by_ref(board, ref).status == :working
    end

    test "an unknown ref is a 404", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/cards/ZZZ-9999") end
    end

    # Deliberately a *different* board key: every board defaults to "RLY", so an
    # other-user board with the default key would collide with this user's own RLY-1
    # and resolve to their card — the assertion would pass for the wrong reason.
    test "another user's card is a 404 — never leaking that it exists", %{conn: conn} do
      other_board = insert(:board, key: "ZZZ", slug: unique_slug("other-board"))
      insert(:membership, board: other_board, user: insert(:user))
      other_stage = insert(:stage, board: other_board, name: "Review", type: :review)
      insert(:card, stage: other_stage, ref_number: 1, title: "Not yours")

      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/cards/ZZZ-1") end
    end

    test "the native card host shows no web prev/next chevrons", %{conn: conn, board: board, ref: ref} do
      for path <- [~p"/cards/#{ref}?board=#{board.slug}", ~p"/cards/#{ref}?board=#{board.slug}&nav=bogus"] do
        {:ok, view, _html} = live(conn, path)
        render_async(view)

        refute has_element?(view, "#card-drawer-nav")
        refute has_element?(view, "#card-drawer-prev")
        refute has_element?(view, "#card-drawer-next")
      end
    end

    # RE400 — `nav=` names the native neighbors; the chevrons call the `relayCardNav` bridge and
    # never the server's prev_card / next_card.
    test "nav=prev,next renders native-mode chevrons that call the bridge, never the server",
         %{conn: conn, board: board, ref: ref} do
      {:ok, view, _html} = live(conn, ~p"/cards/#{ref}?board=#{board.slug}&nav=prev,next")
      render_async(view)

      native = ~s([phx-hook$="NativeCardNav"][data-handler="relayCardNav"])

      assert has_element?(view, "#card-drawer-nav")
      assert has_element?(view, ~s|button#card-drawer-prev:not([disabled])#{native}[data-dir="prev"]|)
      assert has_element?(view, ~s|button#card-drawer-next:not([disabled])#{native}[data-dir="next"]|)

      for id <- ~w(#card-drawer-prev #card-drawer-next), attr <- ~w(phx-click phx-window-keydown phx-key) do
        refute has_element?(view, "#{id}[#{attr}]")
      end
    end

    test "nav=next disables the previous chevron", %{conn: conn, board: board, ref: ref} do
      {:ok, view, _html} = live(conn, ~p"/cards/#{ref}?board=#{board.slug}&nav=next")
      render_async(view)

      assert has_element?(view, "#card-drawer-prev[disabled]")
      assert has_element?(view, "#card-drawer-next:not([disabled])")
    end

    test "native mode binds no arrow keys and mounts no ArrowKeyGuard", %{conn: conn, board: board, ref: ref} do
      {:ok, view, _html} = live(conn, ~p"/cards/#{ref}?board=#{board.slug}&nav=prev,next")
      doc = view |> render_async() |> LazyHTML.from_document()

      assert doc |> LazyHTML.query("#card-drawer-panel") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#card-drawer-panel[phx-hook]") |> Enum.count() == 0
      assert doc |> LazyHTML.query(~s([phx-window-keydown="prev_card"])) |> Enum.count() == 0
      assert doc |> LazyHTML.query(~s([phx-window-keydown="next_card"])) |> Enum.count() == 0
    end

    # RE380 — card mode hosts the same-tab mockup viewer too, keeping `board=` in every URL.
    test "?mockup= opens the chromeless mockup viewer and steps / backs out within /cards/:ref",
         %{conn: conn, board: board, card: card, ref: ref} do
      [a, b] =
        for name <- ~w(a b) do
          {:ok, attachment} =
            Relay.Attachments.create_attachment(card, %{
              filename: "#{name}.html",
              content_type: Schemas.Attachment.html_type(),
              bytes: "<p>#{name}</p>"
            })

          attachment
        end

      {:ok, _card} =
        Cards.set_mockups(card, [
          %{"url" => RelayWeb.attachment_path(a.id), "caption" => "A"},
          %{"url" => RelayWeb.attachment_path(b.id), "caption" => "B"}
        ])

      {:ok, view, _html} = live(conn, ~p"/cards/#{ref}?board=#{board.slug}&mockup=#{a.id}")
      render_async(view)

      assert has_element?(view, "#mockup-viewer")
      assert has_element?(view, "iframe#mockup-viewer-frame")
      refute has_element?(view, "#top-bar")
      refute view |> element("#mockup-viewer") |> render() =~ "drawer:top-[53px]"

      render_hook(view, "mockup_next", %{})
      assert_patch(view, ~p"/cards/#{ref}?board=#{board.slug}&mockup=#{b.id}")

      view |> element("#mockup-viewer-bar-back") |> render_click()
      assert_patch(view, ~p"/cards/#{ref}?board=#{board.slug}")
    end

    test "the native card host does not mount the ArrowKeyGuard hook", %{conn: conn, board: board, ref: ref} do
      {:ok, view, _html} = live(conn, ~p"/cards/#{ref}?board=#{board.slug}")
      render_async(view)

      refute has_element?(view, ~s([phx-hook="ArrowKeyGuard"]))
    end
  end

  # RE393 — the embedded review card owns its top bar: a web nav bar replaces the native AppBar.
  describe "/cards/:ref embed nav bar (RE393)" do
    defp embed_view(conn, path) do
      {:ok, view, _html} = live(conn, path)
      render_async(view)
      view
    end

    defp back_text(view) do
      view
      |> element("#card-drawer-nav-bar-back")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()
    end

    test "one nav bar: the back label, the NativeBack hook, the ref title and the only ⋯",
         %{conn: conn, board: board, ref: ref} do
      view = embed_view(conn, ~p"/cards/#{ref}?board=#{board.slug}&embed=1&back=Board")

      assert back_text(view) == "Board"
      assert has_element?(view, ~s(button#card-drawer-nav-bar-back[phx-hook$="NativeBack"]))
      assert has_element?(view, "#card-drawer-nav-bar-title", ref)

      doc = view |> render() |> LazyHTML.from_fragment()
      assert doc |> LazyHTML.query("#card-drawer-overflow") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#card-drawer-nav-bar #card-drawer-overflow") |> Enum.count() == 1
      assert doc |> LazyHTML.query(".drawer-card-ref") |> Enum.count() == 0
    end

    test "the back label decodes from the URL and falls back to Back",
         %{conn: conn, board: board, ref: ref} do
      assert conn |> embed_view("/cards/#{ref}?board=#{board.slug}&embed=1&back=Needs+you") |> back_text() ==
               "Needs you"

      assert conn |> embed_view(~p"/cards/#{ref}?board=#{board.slug}&embed=1") |> back_text() == "Back"
    end

    test "the tab row is a segmented control with no Talk segment", %{conn: conn, board: board, ref: ref} do
      view = embed_view(conn, ~p"/cards/#{ref}?board=#{board.slug}&embed=1")

      assert has_element?(view, ~s(#card-drawer-tabs [role="group"] #card-drawer-tab-detail[data-active="true"]))
      assert has_element?(view, ~s(#card-drawer-tabs [role="group"] #card-drawer-tab-activity[data-active="false"]))
      refute has_element?(view, "#card-drawer-tab-talk")

      view |> element("#card-drawer-tab-activity") |> render_click()
      assert has_element?(view, ~s(#card-drawer-tab-activity[data-active="true"]))
    end

    test "the review hint points at the native bar; no web decision buttons",
         %{conn: conn, board: board, ref: ref} do
      view = embed_view(conn, ~p"/cards/#{ref}?board=#{board.slug}&embed=1")

      assert has_element?(view, "#review-panel", "Approve or reject below.")
      refute has_element?(view, "#review-approve")
      refute has_element?(view, "#review-request-changes")
    end

    test "the back label survives opening a mockup and coming back",
         %{conn: conn, board: board, card: card, ref: ref} do
      {:ok, a} =
        Relay.Attachments.create_attachment(card, %{
          filename: "a.html",
          content_type: Schemas.Attachment.html_type(),
          bytes: "<p>a</p>"
        })

      {:ok, _card} = Cards.set_mockups(card, [%{"url" => RelayWeb.attachment_path(a.id), "caption" => "A"}])

      view = embed_view(conn, ~p"/cards/#{ref}?board=#{board.slug}&embed=1&back=Board")

      view |> element("#card-drawer-mockup-0-open") |> render_click()
      # ~p canonicalises the query (keys in order), so `back` leads.
      assert_patch(view, "/cards/#{ref}?back=Board&board=#{board.slug}&mockup=#{a.id}")

      view |> element("#mockup-viewer-bar-back") |> render_click()
      assert_patch(view, "/cards/#{ref}?back=Board&board=#{board.slug}")
      assert back_text(view) == "Board"
    end

    test "nav survives opening a mockup and coming back", %{conn: conn, board: board, card: card, ref: ref} do
      {:ok, a} =
        Relay.Attachments.create_attachment(card, %{
          filename: "a.html",
          content_type: Schemas.Attachment.html_type(),
          bytes: "<p>a</p>"
        })

      {:ok, _card} = Cards.set_mockups(card, [%{"url" => RelayWeb.attachment_path(a.id), "caption" => "A"}])

      view = embed_view(conn, ~p"/cards/#{ref}?board=#{board.slug}&embed=1&back=Board&nav=prev,next")

      view |> element("#card-drawer-mockup-0-open") |> render_click()
      assert_patch(view, "/cards/#{ref}?back=Board&board=#{board.slug}&mockup=#{a.id}&nav=prev%2Cnext")

      view |> element("#mockup-viewer-bar-back") |> render_click()
      assert_patch(view, "/cards/#{ref}?back=Board&board=#{board.slug}&nav=prev%2Cnext")
      assert has_element?(view, "#card-drawer-next:not([disabled])")
    end

    test "the dead render covers the notch and scopes the embed scale; the plain board does neither",
         %{conn: conn, user: user, board: board, ref: ref} do
      html = conn |> get(~p"/cards/#{ref}?board=#{board.slug}&embed=1") |> html_response(200)
      assert html =~ "viewport-fit=cover"
      # RE400: the native shell pins the scale, so pinch-zoom can never leave a field zoomed.
      assert html =~ "maximum-scale=1"
      assert html =~ "user-scalable=no"
      assert html =~ "data-embed"

      board_html = build_conn() |> log_in_user(user) |> get(~p"/board/#{board.slug}") |> html_response(200)
      refute board_html =~ "viewport-fit=cover"
      refute board_html =~ "maximum-scale=1"
      refute board_html =~ "user-scalable=no"
      refute board_html =~ "data-embed"
    end
  end

  describe "/cards/:ref with duplicate board keys" do
    # Board keys are not unique. Derive the twin's key and ref_number from the card the
    # outer setup made, so the two boards genuinely produce the same ref string.
    setup %{user: user, board: board, card: card} do
      twin = insert(:board, key: board.key, slug: "twin-board")
      insert(:membership, board: twin, user: user)
      stage = insert(:stage, board: twin, name: "Review", type: :review)
      insert(:card, stage: stage, ref_number: card.ref_number, title: "The twin")

      %{twin: twin}
    end

    test "an ambiguous ref is a 404, not a guess at the wrong card", %{conn: conn, ref: ref} do
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/cards/#{ref}") end
    end

    test "?board= disambiguates", %{conn: conn, board: board, ref: ref, twin: twin} do
      {:ok, view, _html} = live(conn, ~p"/cards/#{ref}?board=#{board.slug}")
      render_async(view)
      assert has_element?(view, "#card-drawer", "Review me")

      {:ok, twin_view, _html} = live(conn, ~p"/cards/#{ref}?board=#{twin.slug}")
      render_async(twin_view)
      assert has_element?(twin_view, "#card-drawer", "The twin")
    end
  end
end
