defmodule RelayWeb.Browser.MockupsTest do
  @moduledoc """
  RE370 / RE374 / RE380 — real-browser checks of a card's HTML mockups.

  The drawer shows them as small square tiles (a sandboxed live miniature each) side by side in
  one row. A tile opens BoardLive's mockup viewer **in the same tab** (`?card=<ref>&mockup=<id>`):
  the card shrinks to a ~340px left sheet and the sandboxed frame sits under a header that names the
  mockup (RE392), which sits directly under the top bar.
  ←/→ switch mockups (never while typing), a half-written reject note survives switching, Esc and
  one browser Back return to the drawer, and the RE370 `/attachments/:id/view` link redirects in.

  `render_keydown/3` and `live/2` never run the client-side key guard, the history stack or the
  layout, so only a real browser proves these.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Activity
  alias Relay.Attachments
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright

  # Bounding boxes of both tiles and the first tile's (CSS-scaled) iframe.
  @measure_tiles """
  (() => {
    const box = (sel) => { const r = document.querySelector(sel).getBoundingClientRect();
      return {top: r.top, left: r.left, w: r.width, h: r.height}; };
    return {t0: box('#card-drawer-mockup-0-open'), t1: box('#card-drawer-mockup-1-open'),
            f0: box('#card-drawer-mockup-0-frame')};
  })()
  """

  # The viewer's left sheet, its header, its frame and the app top bar.
  @measure_viewer """
  (() => {
    const box = (sel) => { const r = document.querySelector(sel).getBoundingClientRect();
      return {top: r.top, bottom: r.bottom, left: r.left, right: r.right, w: r.width, h: r.height}; };
    return {sheet: box('#mockup-viewer-sheet'), header: box('#mockup-viewer-header'),
            frame: box('#mockup-viewer-frame'), topbar: box('#top-bar')};
  })()
  """

  @captions ["Empty state", "Loaded", "Error"]

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    review = Enum.find(board.stages, &(&1.type == :review))

    {card, ids} = card_with_mockups(code, "Mockup card")
    {review_card, review_ids} = card_with_mockups(review, "Review mockup card")
    {:ok, review_card} = Cards.set_status(review_card, %{status: :in_review})

    %{
      board: board,
      card: card,
      ids: ids,
      ref: Cards.ref(board, card),
      review_card: review_card,
      review_ids: review_ids,
      review_ref: Cards.ref(board, review_card)
    }
  end

  defp card_with_mockups(stage, title) do
    {:ok, card} = Cards.create_card(stage, %{title: title})

    attachments =
      for {caption, i} <- Enum.with_index(@captions) do
        {:ok, a} =
          Attachments.create_attachment(card, %{
            filename: "mockup-#{i}.html",
            content_type: Schemas.Attachment.html_type(),
            bytes:
              ~s{<!doctype html><p id="t">before</p><script>document.getElementById("t").textContent = "#{caption}"</script>}
          })

        a
      end

    {:ok, card} =
      Cards.set_mockups(
        card,
        for {a, caption} <- Enum.zip(attachments, @captions) do
          %{"url" => RelayWeb.attachment_path(a.id), "caption" => caption}
        end
      )

    {card, Enum.map(attachments, & &1.id)}
  end

  test "the drawer shows mockups as small square tiles in one row, each a same-tab link", ctx do
    session =
      ctx.conn
      |> open_drawer(ctx.board, ctx.ref)
      |> assert_has("#card-drawer-mockups", text: "Mockups")
      |> assert_has(~s(iframe#card-drawer-mockup-0-frame[sandbox="#{RelayWeb.mockup_sandbox()}"]))
      |> assert_has(~s(a#card-drawer-mockup-0-open[title="Empty state"]))
      |> assert_has(~s(a#card-drawer-mockup-1-open[title="Loaded"]))
      |> refute_has("a#card-drawer-mockup-0-open[target]")

    m = js_eval(session, @measure_tiles)

    for tile <- [m["t0"], m["t1"]] do
      assert tile["w"] <= 81 and tile["h"] <= 81, "tile is not ~80px: #{inspect(tile)}"
      assert abs(tile["w"] - tile["h"]) < 1, "tile is not square: #{inspect(tile)}"
    end

    assert abs(m["t0"]["top"] - m["t1"]["top"]) < 1,
           "two mockups should share one row: #{inspect({m["t0"], m["t1"]})}"

    assert m["t1"]["left"] > m["t0"]["left"]

    # The 1280px iframe is scaled down to fit its tile.
    assert m["f0"]["w"] <= m["t0"]["w"] + 1, "the miniature overflows its tile: #{inspect(m["f0"])}"
  end

  # Scenario 4.
  test "a tile opens the viewer in the same tab: a 340px left sheet beside the frame, the header right under the top bar",
       ctx do
    [id0 | _] = ctx.ids

    session =
      ctx.conn
      |> open_drawer(ctx.board, ctx.ref)
      |> click("#card-drawer-mockup-0-open")
      |> assert_has("#mockup-viewer")
      |> assert_has("#mockup-viewer-sheet")
      |> assert_has("#mockup-viewer-header")
      |> assert_has(~s(iframe#mockup-viewer-frame[src="#{RelayWeb.attachment_path(id0)}"]))

    # THIS page (the one the test drives, not a new tab) is the one now showing the viewer.
    assert search(session) =~ "mockup=#{id0}"

    m = js_eval(session, @measure_viewer)

    assert m["sheet"]["w"] >= 330 and m["sheet"]["w"] <= 350, "sheet is not ~340px: #{inspect(m["sheet"])}"
    assert m["sheet"]["right"] <= m["frame"]["left"] + 1, "sheet is not left of the frame: #{inspect(m)}"
    assert m["frame"]["top"] >= 53, "the frame is under the top bar: #{inspect(m)}"

    assert abs(m["header"]["top"] - m["topbar"]["bottom"]) <= 1,
           "the header is not right under the top bar: #{inspect(m)}"

    assert m["frame"]["top"] >= m["header"]["bottom"], "the frame is not under the header: #{inspect(m)}"
  end

  # Scenario 5.
  test "a tile then ArrowRight switches mockups", ctx do
    [_id0, id1, _id2] = ctx.ids

    ctx.conn
    |> open_viewer(ctx.board, ctx.ref, id1)
    |> click("#mockup-viewer-mockup-1-open")
    |> assert_has("#mockup-viewer-header-count", text: "2 of 3")
    |> press_on("body", "ArrowRight")
    |> assert_has("#mockup-viewer-header-caption", text: "Error")
    |> assert_has("#mockup-viewer-header-count", text: "3 of 3")
    |> assert_has(~s(#mockup-viewer-mockup-2-open[aria-current="true"]))
    |> refute_has("#mockup-viewer-mockups-viewing")
    |> refute_has("#mockup-viewer-mockups-keys")
  end

  # Scenario 6.
  test "arrows typed in the reject note never switch; the note survives switching; Quote and Send back",
       ctx do
    [id0 | _] = ctx.review_ids

    session =
      ctx.conn
      |> open_viewer(ctx.board, ctx.review_ref, id0)
      |> click("#review-request-changes")
      |> assert_has("#review-request-note")
      |> type_into("#review-request-note", "keep the filter")
      |> press_on("#review-request-note", "ArrowLeft")
      |> press_on("#review-request-note", "ArrowRight")

    # A switch would have patched; give it the chance, then prove it never happened.
    Process.sleep(300)
    assert search(session) =~ "mockup=#{id0}"
    session = assert_has(session, "#mockup-viewer-header-count", text: "1 of 3")

    session =
      session
      |> click("#mockup-viewer-mockup-1-open")
      |> assert_has("#mockup-viewer-header-count", text: "2 of 3")

    assert note_value(session) =~ ~r/^keep the filter/

    session =
      session
      |> assert_has("#review-quote-caption", text: "Loaded")
      |> click("#review-quote-caption")

    assert note_value(session) =~ "“Loaded”"

    session
    |> click("#review-send-back")
    |> refute_has("#mockup-viewer")
    |> assert_path("/board/#{ctx.board.slug}")

    rejected =
      ctx.board
      |> Cards.get_card_by_ref(ctx.review_ref)
      |> Activity.list_timeline()
      |> Enum.find(&match?(%Schemas.Activity{type: :rejected}, &1))

    assert rejected, "no :rejected timeline entry"
    assert rejected.meta["note"] =~ "keep the filter"
    assert rejected.meta["note"] =~ "“Loaded”"
  end

  # Scenario 7.
  test "one browser Back leaves the viewer however many times you switched", ctx do
    session =
      ctx.conn
      |> open_drawer(ctx.board, ctx.ref)
      |> click("#card-drawer-mockup-0-open")
      |> assert_has("#mockup-viewer-header-count", text: "1 of 3")
      |> press_on("body", "ArrowRight")
      |> assert_has("#mockup-viewer-header-count", text: "2 of 3")
      |> press_on("body", "ArrowRight")
      |> assert_has("#mockup-viewer-header-count", text: "3 of 3")

    js_eval(session, "(() => { history.back(); return true })()")

    session = refute_has(session, "#mockup-viewer")

    assert visible?(session, "#card-drawer-panel")
    assert search(session) == "?card=#{ctx.ref}"
  end

  # Scenario 8.
  test "Esc leaves the viewer for the card drawer", ctx do
    [id0 | _] = ctx.ids

    session =
      ctx.conn
      |> open_viewer(ctx.board, ctx.ref, id0)
      |> press_on("body", "Escape")
      |> refute_has("#mockup-viewer")

    assert visible?(session, "#card-drawer-panel")
    refute search(session) =~ "mockup"
  end

  # Scenario 9.
  test "an RE370 /attachments/:id/view link lands on the same-tab viewer", ctx do
    [_id0, id1, _id2] = ctx.ids

    session =
      ctx.conn
      |> visit("/dev/login")
      |> assert_has("body .phx-connected")
      |> visit(RelayWeb.attachment_view_path(id1))
      |> assert_has("#mockup-viewer")
      |> assert_has(~s(#mockup-viewer-mockup-1-open[aria-current="true"]))

    assert search(session) =~ "mockup=#{id1}"
  end

  defp open_drawer(conn, board, ref) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}?card=#{ref}")
    |> assert_has("#card-drawer-panel")
    # Keys pressed before THIS page's socket binds its window listeners are lost.
    |> assert_has("body .phx-connected")
  end

  defp open_viewer(conn, board, ref, id) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}?card=#{ref}&mockup=#{id}")
    |> assert_has("#mockup-viewer")
    |> assert_has("body .phx-connected")
  end

  defp press_on(session, selector, key) do
    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.press(frame_id, selector: selector, key: key, timeout: 2_000)
    end)
  end

  defp type_into(session, selector, text) do
    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.type(frame_id, selector: selector, text: text, timeout: 2_000)
    end)
  end

  defp note_value(session) do
    js_eval(session, ~s|(() => document.getElementById("review-request-note").value)()|)
  end

  defp visible?(session, selector) do
    js_eval(session, "(() => { const el = document.querySelector('#{selector}'); return !!(el && el.offsetParent) })()")
  end

  defp search(session), do: js_eval(session, "(() => window.location.search)()")

  defp js_eval(session, expression) do
    parent = self()

    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, value} = Frame.evaluate(frame_id, expression: expression, timeout: 2_000)
      send(parent, {:evaluated, value})
    end)

    assert_received {:evaluated, value}
    value
  end
end
