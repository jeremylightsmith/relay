defmodule HamacaWeb.BoardLiveDependenciesTest do
  @moduledoc "RE93 — the face chip and the drawer's two dependency rails."
  use HamacaWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Hamaca.Cards

  setup :register_and_log_in_user

  setup %{conn: conn, user: user} do
    board = insert(:board, owner: user, key: "RE")
    insert(:membership, board: board, user: user)

    next_up = insert(:stage, board: board, name: "Next up", category: :unstarted, type: :queue, position: 1)
    done = insert(:stage, board: board, name: "Done", category: :complete, type: :done, position: 2)

    a = insert(:card, stage: next_up, ref_number: 1, title: "Dependent")
    b = insert(:card, stage: next_up, ref_number: 2, title: "Blocker B")
    c = insert(:card, stage: next_up, ref_number: 3, title: "Blocker C")

    %{conn: conn, board: board, next_up: next_up, done: done, a: a, b: b, c: c}
  end

  defp open_board(ctx) do
    {:ok, view, html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")
    {view, html}
  end

  # The drawer body loads async (RLY-68): without render_async the rails are still a skeleton
  # and every assertion below would miss.
  defp open_drawer(ctx, ref \\ "RE1") do
    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}?card=#{ref}")
    render_async(view)
    view
  end

  # LiveViewTest has `refute_redirected/1` but no patch counterpart; a push_patch lands in the
  # test process as this message, so its absence is "no patch happened".
  defp refute_patched(%{proxy: {ref, topic, _}}), do: refute_received({^ref, {:patch, ^topic, _}})

  test "the face chip counts unmet blockers and pluralizes", ctx do
    {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2", "RE3"])
    {view, html} = open_board(ctx)

    assert html =~ "Blocked by 2 cards"
    assert has_element?(view, ".card-blocked-chip")

    {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
    assert render(view) =~ "Blocked by 1 card"
  end

  test "the drawer lists both directions", ctx do
    {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2", "RE3"])
    view = open_drawer(ctx)

    assert has_element?(view, "#card-drawer-blocked-by-RE2")
    assert has_element?(view, "#card-drawer-blocked-by-RE3")

    blocker_view = open_drawer(ctx, "RE2")
    assert has_element?(blocker_view, "#card-drawer-blocks-RE1")
  end

  test "adding a blocker from the drawer round-trips", ctx do
    view = open_drawer(ctx)

    view |> element("#card-drawer-add-dependency") |> render_submit(%{"ref" => "RE2"})

    assert has_element?(view, "#card-drawer-blocked-by-RE2")
    assert [%{ref: "RE2"}] = Cards.list_dependencies(ctx.board, ctx.a)
  end

  test "removing a blocker round-trips", ctx do
    {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2", "RE3"])
    view = open_drawer(ctx)

    view |> element("#card-drawer-blocked-by-remove-RE3") |> render_click()

    assert [%{ref: "RE2"}] = Cards.list_dependencies(ctx.board, ctx.a)
    refute has_element?(view, "#card-drawer-blocked-by-RE3")
  end

  test "an unknown ref and a cycle both render inline under the input, not as a flash", ctx do
    view = open_drawer(ctx)

    view |> element("#card-drawer-add-dependency") |> render_submit(%{"ref" => "ZZ999"})
    assert has_element?(view, "#card-drawer-dependency-error")
    html = render(view)
    assert html =~ "this board has no card with ref: ZZ999"

    # "under the input" is the fidelity spec, so pin the order, not just the presence.
    assert :binary.match(html, "card-drawer-dependency-error") >
             :binary.match(html, "card-drawer-add-dependency")

    {:ok, _} = Cards.set_dependencies(ctx.board, ctx.b, ["RE1"])
    view |> element("#card-drawer-add-dependency") |> render_submit(%{"ref" => "RE2"})
    assert render(view) =~ "that would create a dependency cycle: RE1 → RE2 → RE1"
  end

  # RE93 — refresh_blocked_by/2 runs on EVERY board broadcast while a drawer is open. It must
  # not carry the drawer's inline error away with it: an agent touching any other card on an
  # AI-first board would otherwise erase the refusal the reader is still reading.
  test "an unrelated board broadcast leaves the inline error standing", ctx do
    view = open_drawer(ctx)

    view |> element("#card-drawer-add-dependency") |> render_submit(%{"ref" => "ZZ999"})
    assert has_element?(view, "#card-drawer-dependency-error")

    {:ok, _} = Cards.update_card(ctx.c, %{title: "Blocker C, retitled"})

    assert has_element?(view, "#card-drawer-dependency-error")
    assert render(view) =~ "this board has no card with ref: ZZ999"
  end

  test "a satisfied blocker is ticked in the drawer", ctx do
    {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
    view = open_drawer(ctx)

    {:ok, _} = Cards.move_card(ctx.b, ctx.done, 0, :agent)

    assert has_element?(view, ~s(#card-drawer-blocked-by-RE2[data-satisfied="true"]))
  end

  test "finishing a blocker removes the dependent's chip live, with no reload", ctx do
    {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
    {view, html} = open_board(ctx)
    assert html =~ "Blocked by 1 card"

    {:ok, _} = Cards.move_card(ctx.b, ctx.done, 0, :agent)

    refute render(view) =~ "Blocked by 1 card"
  end

  test "archiving a blocker frees its dependent live", ctx do
    {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
    {view, _html} = open_board(ctx)

    {:ok, _} = Cards.archive_card(ctx.b)

    refute render(view) =~ "Blocked by"
    assert Cards.list_dependencies(ctx.board, ctx.a) == []
  end

  test "the Blocks rail is hidden entirely when the card blocks nothing", ctx do
    view = open_drawer(ctx)
    refute has_element?(view, "#card-drawer-blocks")
  end

  # RE93 — the box's text is server-held precisely so the success path can empty it: a bare
  # uncontrolled input keeps what you typed (morphdom will not clear a `value` the server never
  # rendered), so adding a second blocker would mean clearing the box by hand first.
  test "the add-blocker box empties after a successful add and keeps a refused ref", ctx do
    view = open_drawer(ctx)

    view |> element("#card-drawer-add-dependency") |> render_change(%{"ref" => "RE2"})
    assert has_element?(view, ~s(#card-drawer-add-dependency input[value="RE2"]))

    view |> element("#card-drawer-add-dependency") |> render_submit(%{"ref" => "RE2"})

    assert has_element?(view, "#card-drawer-blocked-by-RE2")
    assert has_element?(view, ~s(#card-drawer-add-dependency input[value=""]))

    # A refusal is about the text you just typed, so that text must survive to be corrected.
    view |> element("#card-drawer-add-dependency") |> render_change(%{"ref" => "ZZ999"})
    view |> element("#card-drawer-add-dependency") |> render_submit(%{"ref" => "ZZ999"})
    assert has_element?(view, "#card-drawer-dependency-error")
    assert has_element?(view, ~s(#card-drawer-add-dependency input[value="ZZ999"]))
  end

  # RE93 — refresh_blocked_by/2 rebuilds the datalist from the card list its caller ALREADY
  # loaded, rather than issuing a second whole-board select with preloads on every broadcast.
  # This pins the property that made the re-query look necessary: the options must still pick up
  # a card another session just created, with no reload.
  test "the datalist picks up a card created by another session, with no reload", ctx do
    view = open_drawer(ctx)
    refute render(view) =~ "Freshly created elsewhere"

    # The factory seeded refs 1-3 without moving the board's counter, so let create_card allocate
    # from there and go through the real broadcast another session would emit.
    Hamaca.Repo.update_all(from(b in Schemas.Board, where: b.id == ^ctx.board.id), set: [card_seq: 3])
    {:ok, _card} = Cards.create_card(ctx.next_up, %{title: "Freshly created elsewhere"})

    assert has_element?(view, ~s(#card-drawer-dependency-options option[value="RE4"]))
    assert render(view) =~ "Freshly created elsewhere"
  end

  describe "dependency chips link to their card (RE474)" do
    test "each Blocked by and Blocks chip links to its card's drawer URL", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
      view = open_drawer(ctx)

      assert has_element?(view, ~s(#card-drawer-blocked-by-link-RE2[href="/board/#{ctx.board.slug}?card=RE2"]))

      blocker_view = open_drawer(ctx, "RE2")
      assert has_element?(blocker_view, ~s(#card-drawer-blocks-link-RE1[href*="?card=RE1"]))
    end

    test "clicking a blocker chip opens that card in the drawer in place", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
      view = open_drawer(ctx)

      view |> element("#card-drawer-blocked-by-link-RE2") |> render_click()

      assert_patch(view, "/board/#{ctx.board.slug}?card=RE2")
      render_async(view)
      assert has_element?(view, "#card-drawer-blocks-RE1")
    end

    test "✕ removes the blocker without navigating", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2", "RE3"])
      view = open_drawer(ctx)

      view |> element("#card-drawer-blocked-by-remove-RE3") |> render_click()

      assert [%{ref: "RE2"}] = Cards.list_dependencies(ctx.board, ctx.a)
      refute_patched(view)
      assert has_element?(view, "#card-drawer-blocked-by-RE2")
    end

    test "the web + Add datalist input is unchanged", ctx do
      view = open_drawer(ctx)

      assert has_element?(view, ~s(#card-drawer-dependency-input[list="card-drawer-dependency-options"]))
      assert has_element?(view, "datalist#card-drawer-dependency-options")
    end
  end

  describe "embed Properties tab (RE474)" do
    defp open_embed(ctx, ref) do
      {:ok, view, _html} = live(ctx.conn, ~p"/cards/#{ref}?board=#{ctx.board.slug}&embed=1")
      render_async(view)
      view
    end

    defp open_properties(ctx, ref \\ "RE1") do
      view = open_embed(ctx, ref)
      view |> element("#card-drawer-tab-properties") |> render_click()
      view
    end

    defp open_add_box(view) do
      view |> element("#card-drawer-add-dependency-open") |> render_click()
      view
    end

    defp type_dependency(view, text) do
      view |> element("#card-drawer-add-dependency") |> render_change(%{"ref" => text})
      view
    end

    defp suggestion_ids(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([id^="card-drawer-dependency-suggestion-"]))
      |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))
    end

    test "web has no Properties tab and ignores a drawer_tab of properties", ctx do
      view = open_drawer(ctx)

      refute has_element?(view, "#card-drawer-tab-properties")
      assert has_element?(view, "#card-drawer-rail")

      render_hook(view, "drawer_tab", %{"tab" => "properties"})

      assert has_element?(view, ~s(#card-drawer-tab-detail[data-active="true"]))
      assert has_element?(view, "#card-drawer-rail")
    end

    test "Blocked by renders 44px touch rows with ✕, links and an Add blocker button", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2", "RE3"])
      {:ok, _} = Cards.move_card(ctx.c, ctx.done, 0, :agent)
      view = open_properties(ctx)

      assert has_element?(view, "#card-drawer-blocked-by-RE2.min-h-11")
      assert has_element?(view, "#card-drawer-blocked-by-link-RE2 .hero-lock-closed")
      assert has_element?(view, ~s(#card-drawer-blocked-by-RE3[data-satisfied="true"] .hero-check-circle))
      assert has_element?(view, "#card-drawer-blocked-by-remove-RE2")
      assert has_element?(view, "#card-drawer-blocked-by-remove-RE3")
      assert has_element?(view, ~s(#card-drawer-blocked-by-link-RE2[href*="?card=RE2"]))
      assert has_element?(view, ~s(#card-drawer-blocked-by-link-RE3[href*="?card=RE3"]))

      assert has_element?(
               view,
               ~s(button#card-drawer-add-dependency-open[type="button"].min-h-11.border-dashed),
               "Add blocker"
             )

      refute has_element?(view, "#card-drawer datalist")
      refute has_element?(view, "#card-drawer [list]")
    end

    test "Blocks is read-only and hidden when the card blocks nothing", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])

      view = open_properties(ctx, "RE2")
      assert has_element?(view, "#card-drawer-blocks-RE1 .hero-arrow-turn-down-right")
      refute has_element?(view, "#card-drawer-blocks-remove-RE1")

      view = open_properties(ctx, "RE3")
      refute has_element?(view, "#card-drawer-blocks")
    end

    test "Add blocker opens the touch box with an empty suggestion list", ctx do
      view = open_properties(ctx)

      assert has_element?(view, "#card-drawer-blocked-by", "None")
      refute has_element?(view, "#card-drawer-add-dependency")

      open_add_box(view)

      assert has_element?(view, "form#card-drawer-add-dependency")
      assert has_element?(view, ~s(#card-drawer-dependency-input[name="ref"].input-primary.h-11))
      refute has_element?(view, "#card-drawer-dependency-input[list]")
      assert has_element?(view, "#card-drawer-add-dependency-cancel", "Cancel")
      refute has_element?(view, "#card-drawer-add-dependency-open")
      assert suggestion_ids(view) == []
    end

    test "typing filters the suggestions by title and ref, never offering the card itself", ctx do
      view = ctx |> open_properties() |> open_add_box() |> type_dependency("blocker")

      assert has_element?(view, ~s(#card-drawer-dependency-suggestions[class*="rounded-[10px]"]))
      assert has_element?(view, "#card-drawer-dependency-suggestion-RE2", "Blocker B")
      assert has_element?(view, "#card-drawer-dependency-suggestion-RE3", "Blocker C")
      refute has_element?(view, "#card-drawer-dependency-suggestion-RE1")

      type_dependency(view, "re3")
      assert suggestion_ids(view) == ["card-drawer-dependency-suggestion-RE3"]
    end

    test "current blockers are left out of the suggestions", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
      view = ctx |> open_properties() |> open_add_box() |> type_dependency("blocker")

      assert suggestion_ids(view) == ["card-drawer-dependency-suggestion-RE3"]
    end

    test "the suggestion list is capped at five rows", ctx do
      for i <- 1..7, do: insert(:card, stage: ctx.next_up, ref_number: 3 + i, title: "Match #{i}")
      view = ctx |> open_properties() |> open_add_box() |> type_dependency("match")

      assert length(suggestion_ids(view)) == 5
    end

    test "tapping a suggestion adds the blocker, closes the box and stays on Properties", ctx do
      view = ctx |> open_properties() |> open_add_box() |> type_dependency("blocker")

      view |> element("#card-drawer-dependency-suggestion-RE2") |> render_click()

      assert [%{ref: "RE2"}] = Cards.list_dependencies(ctx.board, ctx.a)
      assert has_element?(view, "#card-drawer-blocked-by-RE2")
      refute has_element?(view, "#card-drawer-add-dependency")
      assert has_element?(view, "#card-drawer-add-dependency-open")
      assert has_element?(view, ~s(#card-drawer-tab-properties[data-active="true"]))
    end

    test "a refused ref keeps the box open with the inline error and the typed text", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.b, ["RE1"])
      view = ctx |> open_properties() |> open_add_box() |> type_dependency("RE2")

      view |> element("#card-drawer-add-dependency") |> render_submit(%{"ref" => "RE2"})

      message = Cards.dependency_error_message({:dependency_cycle, ["RE1", "RE2", "RE1"]})
      assert message =~ "RE2"
      assert view |> element("#card-drawer-dependency-error") |> render() =~ message
      assert has_element?(view, ~s(#card-drawer-dependency-input[value="RE2"]))
      assert has_element?(view, "#card-drawer-add-dependency")
      assert Cards.list_dependencies(ctx.board, ctx.a) == []
    end

    test "Cancel closes the box and clears its text, error and suggestions", ctx do
      view = ctx |> open_properties() |> open_add_box() |> type_dependency("ZZ")
      view |> element("#card-drawer-add-dependency") |> render_submit(%{"ref" => "ZZ"})
      assert has_element?(view, "#card-drawer-dependency-error")

      view |> element("#card-drawer-add-dependency-cancel") |> render_click()

      refute has_element?(view, "#card-drawer-add-dependency")
      refute has_element?(view, "#card-drawer-dependency-error")
      refute has_element?(view, "#card-drawer-dependency-suggestions")
      assert has_element?(view, "#card-drawer-add-dependency-open")

      open_add_box(view)
      assert has_element?(view, ~s(#card-drawer-dependency-input[value=""]))
    end

    test "✕ removes a blocker without tapping through to it", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2", "RE3"])
      view = open_properties(ctx)

      view |> element("#card-drawer-blocked-by-remove-RE3") |> render_click()

      assert [%{ref: "RE2"}] = Cards.list_dependencies(ctx.board, ctx.a)
      refute has_element?(view, "#card-drawer-blocked-by-RE3")
      refute_push_event(view, "card-tap", _)

      {_board_view, board_html} = open_board(ctx)
      assert board_html =~ "Blocked by 1 card"
    end

    test "tapping a blocker row hands that card to the native shell", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
      view = open_properties(ctx)

      view |> element("#card-drawer-blocked-by-link-RE2") |> render_click()

      slug = ctx.board.slug
      assert_push_event(view, "card-tap", %{ref: "RE2", board: ^slug, cards: cards})
      assert is_list(cards)
    end

    test "an archived card shows its blockers read-only", ctx do
      {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
      {:ok, _} = Cards.archive_card(ctx.a, {:user, ctx.user.id})
      view = open_properties(ctx)

      assert has_element?(view, "#card-drawer-blocked-by-RE2")
      refute has_element?(view, "#card-drawer-blocked-by-remove-RE2")
      refute has_element?(view, "#card-drawer-add-dependency-open")
    end

    test "switching card closes the add box", ctx do
      ctx |> open_properties() |> open_add_box()

      fresh = open_properties(ctx, "RE2")
      assert has_element?(fresh, "#card-drawer-add-dependency-open")

      view = ctx |> open_properties() |> open_add_box()
      render_patch(view, ~p"/cards/RE2?board=#{ctx.board.slug}&embed=1")
      render_async(view)
      view |> element("#card-drawer-tab-properties") |> render_click()

      assert has_element?(view, "#card-drawer-title", "Blocker B")
      assert has_element?(view, "#card-drawer-add-dependency-open")
    end
  end
end
