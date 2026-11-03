defmodule HamacaWeb.BoardLiveStoryMapSelectionTest do
  @moduledoc """
  RE502 — building a selection on the story map: the card checkbox (and the ⇧-click hook's
  `toggle_card_selection`), the tri-state step and release boxes, the bulk bar shell, layered
  Esc, pruning as cards leave the visible set, and no selection at all on a read-only board.
  """
  use HamacaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Hamaca.Boards
  alias Hamaca.Cards
  alias Hamaca.StoryMap
  alias HamacaWeb.StoryMapFilter
  alias HamacaWeb.StoryMapGrid

  setup :register_and_log_in_user

  # The same map as `BoardLiveStoryMapTest`: `sso` on Sign in / MVP, `bulk` on Organize / Fast
  # follow, `audit` on Onboard with no step / MVP, `limits` on Sign in with no release (so it
  # renders in the last lane, Later), `dashboards` unmapped.
  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    [backlog | _rest] = board.stages

    {:ok, onboard} = StoryMap.create_activity(board, %{name: "Onboard & access", position: 1})
    {:ok, plan} = StoryMap.create_activity(board, %{name: "Plan the backlog", position: 2})
    {:ok, sign_in} = StoryMap.create_step(onboard, %{name: "Sign in", position: 1})
    {:ok, organize} = StoryMap.create_step(plan, %{name: "Organize cards", position: 1})
    [mvp, fast_follow, later] = StoryMap.list_releases(board)

    {:ok, sso} = Cards.create_card(backlog, %{title: "Add SSO"})
    {:ok, bulk} = Cards.create_card(backlog, %{title: "Bulk edit"})
    {:ok, audit} = Cards.create_card(backlog, %{title: "Audit auth errors"})
    {:ok, limits} = Cards.create_card(backlog, %{title: "Rate limits"})
    {:ok, dashboards} = Cards.create_card(backlog, %{title: "Shared dashboards"})

    {:ok, sso} = StoryMap.assign_card(sso, %{story_step_id: sign_in.id, release_id: mvp.id})
    {:ok, bulk} = StoryMap.assign_card(bulk, %{story_step_id: organize.id, release_id: fast_follow.id})
    {:ok, audit} = StoryMap.assign_card(audit, %{story_activity_id: onboard.id, release_id: mvp.id})
    {:ok, limits} = StoryMap.assign_card(limits, %{story_step_id: sign_in.id})

    %{
      board: board,
      onboard: onboard,
      plan: plan,
      sign_in: sign_in,
      organize: organize,
      mvp: mvp,
      later: later,
      sso: sso,
      bulk: bulk,
      audit: audit,
      limits: limits,
      dashboards: dashboards
    }
  end

  defp map_path(board), do: ~p"/board/#{board.slug}/story-map"
  defp ref(board, card), do: Cards.ref(board, card)
  defp checkbox(board, card), do: "#story-map-card-#{ref(board, card)}-select"

  defp toggle(view, board, card), do: render_hook(view, "toggle_card_selection", %{"ref" => ref(board, card)})

  defp bar_count(view), do: view |> element("#story-map-bulk-bar .badge") |> render() |> text()

  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()

  defp classes(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("class")
    |> List.first("")
    |> String.split()
  end

  defp count(view, selector), do: view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.count()

  describe "toggling cards (scenarios 8, 9)" do
    test "toggle_card_selection builds a selection and the bar, without opening the drawer",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, map_path(ctx.board))
      refute has_element?(view, "#story-map-bulk-bar")

      toggle(view, ctx.board, ctx.sso)
      toggle(view, ctx.board, ctx.bulk)

      assert bar_count(view) == "2 selected"
      assert has_element?(view, "#story-map-bulk-stage")
      assert has_element?(view, "#story-map-bulk-release")
      assert has_element?(view, "#story-map-bulk-step")
      assert has_element?(view, "#story-map-bulk-clear")

      assert has_element?(view, ~s(#{checkbox(ctx.board, ctx.sso)}[aria-pressed="true"]))
      assert has_element?(view, ~s(#{checkbox(ctx.board, ctx.bulk)}[aria-pressed="true"]))
      assert has_element?(view, ~s(#{checkbox(ctx.board, ctx.audit)}[aria-pressed="false"]))

      refute_received {_ref, {:patch, _topic, _opts}}
      refute has_element?(view, "#card-drawer")
    end

    test "the checkbox toggles off, and a plain card click still opens the drawer",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, map_path(ctx.board))
      toggle(view, ctx.board, ctx.sso)
      toggle(view, ctx.board, ctx.bulk)

      view |> element(checkbox(ctx.board, ctx.sso)) |> render_click()
      assert bar_count(view) == "1 selected"

      view |> element("#story-map-card-#{ref(ctx.board, ctx.audit)}") |> render_click()
      assert_patch(view, ~p"/board/#{ctx.board.slug}/story-map?card=#{ref(ctx.board, ctx.audit)}")
      assert bar_count(view) == "1 selected"
    end
  end

  describe "the select-all boxes (scenarios 10, 12)" do
    setup ctx do
      {:ok, mine} = Cards.add_owner(ctx.sso, {:user, ctx.user.id})
      %{mine: mine}
    end

    test "a step box selects only the visible cards under it, and reports its state",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, map_path(ctx.board))
      box = "#" <> StoryMapGrid.select_box_id(:column, "s:#{ctx.sign_in.id}")

      # Only `sso` is the user's: the filter hides `limits`, which shares the Sign in column.
      view |> element("##{StoryMapFilter.chip_dom_id("u:#{ctx.user.id}")}") |> render_click()
      refute has_element?(view, "#story-map-card-#{ref(ctx.board, ctx.limits)}")

      view |> element(box) |> render_click()

      assert has_element?(view, ~s(#{checkbox(ctx.board, ctx.sso)}[aria-pressed="true"]))
      assert bar_count(view) == "1 selected"
      assert has_element?(view, ~s(#{box}[data-state="all"]))

      toggle(view, ctx.board, ctx.sso)
      assert has_element?(view, ~s(#{box}[data-state="none"]))
    end

    test "a box with some of its cards selected is partial", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, map_path(ctx.board))
      box = "#" <> StoryMapGrid.select_box_id(:column, "s:#{ctx.sign_in.id}")

      view |> element(box) |> render_click()
      assert bar_count(view) == "2 selected"
      assert has_element?(view, ~s(#{box}[data-state="all"]))

      toggle(view, ctx.board, ctx.limits)
      assert has_element?(view, ~s(#{box}[data-state="some"]))
    end

    test "a release box selects every visible card in its lane", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, map_path(ctx.board))
      box = "#" <> StoryMapGrid.select_box_id(:lane, "r:#{ctx.mvp.id}")

      view |> element(box) |> render_click()

      # MVP's lane holds `sso` (Sign in) and `audit` (Onboard, no step).
      assert bar_count(view) == "2 selected"
      assert has_element?(view, ~s(#{checkbox(ctx.board, ctx.sso)}[aria-pressed="true"]))
      assert has_element?(view, ~s(#{checkbox(ctx.board, ctx.audit)}[aria-pressed="true"]))
      assert has_element?(view, ~s(#{box}[data-state="all"]))
    end
  end

  describe "pruning (scenarios 11, 17)" do
    test "a filter that hides a selected card drops it, and clearing the filter does not restore it",
         %{conn: conn} = ctx do
      {:ok, _mine} = Cards.add_owner(ctx.sso, {:user, ctx.user.id})
      {:ok, view, _html} = live(conn, map_path(ctx.board))
      toggle(view, ctx.board, ctx.sso)
      toggle(view, ctx.board, ctx.bulk)

      view |> element("##{StoryMapFilter.chip_dom_id("u:#{ctx.user.id}")}") |> render_click()
      assert bar_count(view) == "1 selected"

      view |> element("#story-map-clear-filters") |> render_click()
      assert has_element?(view, "#story-map-card-#{ref(ctx.board, ctx.bulk)}")
      assert has_element?(view, ~s(#{checkbox(ctx.board, ctx.bulk)}[aria-pressed="false"]))
      assert bar_count(view) == "1 selected"
    end

    test "a selected card unmapped by another actor leaves the selection", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, map_path(ctx.board))
      toggle(view, ctx.board, ctx.sso)
      assert bar_count(view) == "1 selected"

      {:ok, _unmapped} = StoryMap.unassign_card(ctx.sso)

      refute has_element?(view, "#story-map-bulk-bar")
    end
  end

  describe "the bulk bar (scenarios 13, 14)" do
    test "Esc closes the open menu first, then clears the selection", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, map_path(ctx.board))
      toggle(view, ctx.board, ctx.sso)
      toggle(view, ctx.board, ctx.bulk)

      render_hook(view, "open_bulk_menu", %{"menu" => "stage"})
      assert "btn-primary" in classes(view, "#story-map-bulk-stage")

      render_hook(view, "story_map_selection_escape", %{})
      refute "btn-primary" in classes(view, "#story-map-bulk-stage")
      assert bar_count(view) == "2 selected"

      render_hook(view, "story_map_selection_escape", %{})
      refute has_element?(view, "#story-map-bulk-bar")
    end

    test "the same menu again closes it, and an unknown menu is a no-op", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, map_path(ctx.board))
      toggle(view, ctx.board, ctx.sso)

      view |> element("#story-map-bulk-release") |> render_click()
      assert "btn-primary" in classes(view, "#story-map-bulk-release")

      render_hook(view, "open_bulk_menu", %{"menu" => "owner"})
      assert "btn-primary" in classes(view, "#story-map-bulk-release")

      view |> element("#story-map-bulk-release") |> render_click()
      refute "btn-primary" in classes(view, "#story-map-bulk-release")
    end

    test "✕ clears the selection", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, map_path(ctx.board))
      toggle(view, ctx.board, ctx.sso)
      toggle(view, ctx.board, ctx.bulk)

      view |> element("#story-map-bulk-clear") |> render_click()

      refute has_element?(view, "#story-map-bulk-bar")
      assert has_element?(view, ~s(#{checkbox(ctx.board, ctx.sso)}[aria-pressed="false"]))
    end
  end

  describe "read-only boards have no selection (scenario 15)" do
    test "an archived board renders no boxes and ignores the events", %{conn: conn} = ctx do
      {:ok, _archived} = Boards.archive_board(ctx.board)
      {:ok, view, _html} = live(conn, map_path(ctx.board))

      assert_no_selection(view, ctx)
    end

    test "a paused board renders no boxes and ignores the events", %{conn: conn, user: user} = ctx do
      Process.put(:billing_enabled, true)
      insert(:billing_account, user: user, held_on: Date.utc_today(), hold_reason: "test")
      {:ok, view, _html} = live(conn, map_path(ctx.board))

      assert_no_selection(view, ctx)
    end
  end

  defp assert_no_selection(view, ctx) do
    assert has_element?(view, "#story-map-card-#{ref(ctx.board, ctx.sso)}")
    assert count(view, ~s(.story-map-card [id$="-select"])) == 0
    assert count(view, ~s([id^="story-map-select-"])) == 0
    assert has_element?(view, ~s(#story-map-grid[data-selectable="false"]))

    toggle(view, ctx.board, ctx.sso)
    render_hook(view, "toggle_selection_group", %{"kind" => "column", "key" => "s:#{ctx.sign_in.id}"})
    render_hook(view, "open_bulk_menu", %{"menu" => "stage"})
    refute has_element?(view, "#story-map-bulk-bar")
  end

  describe "the tray (scenario 16)" do
    test "an unmapped card has no checkbox and cannot be selected", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, map_path(ctx.board))

      assert has_element?(view, "#story-map-tray-card-#{ref(ctx.board, ctx.dashboards)}")
      assert has_element?(view, ~s(#story-map-grid[data-selectable="true"]))
      assert count(view, ~s(#story-map-tray [id$="-select"])) == 0

      toggle(view, ctx.board, ctx.dashboards)
      refute has_element?(view, "#story-map-bulk-bar")
    end

    test "an unknown ref and an unknown group kind are no-ops", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, map_path(ctx.board))

      render_hook(view, "toggle_card_selection", %{"ref" => "NOPE-999"})
      render_hook(view, "toggle_selection_group", %{"kind" => "band", "key" => "s:#{ctx.sign_in.id}"})

      refute has_element?(view, "#story-map-bulk-bar")
    end
  end

  describe "layered Esc (scenario 18)" do
    @escape ~s([phx-window-keydown="story_map_selection_escape"])

    test "the selection's Esc binding yields to an open drawer", %{conn: conn} = ctx do
      {:ok, view, _html} =
        live(conn, ~p"/board/#{ctx.board.slug}/story-map?card=#{ref(ctx.board, ctx.audit)}")

      assert has_element?(view, "#card-drawer")
      toggle(view, ctx.board, ctx.sso)
      assert bar_count(view) == "1 selected"

      assert count(view, @escape) == 0
    end

    test "with the drawer closed exactly one element binds Esc to the selection",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, map_path(ctx.board))
      assert count(view, @escape) == 0

      toggle(view, ctx.board, ctx.sso)

      assert count(view, @escape <> ~s([phx-key="Escape"])) == 1
      assert count(view, @escape) == 1
    end
  end
end
