defmodule RelayWeb.BoardLiveDependenciesTest do
  @moduledoc "RE93 — the face chip and the drawer's two dependency rails."
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Cards

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
end
