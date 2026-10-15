defmodule RelayWeb.Browser.BoardMoveScrollTest do
  @moduledoc """
  Real-browser (Playwright) tests for RE454: moving a card must not scroll its column back to
  the top.

  `BoardLive.apply_move/3` resets the source and target stage streams (`reset: true`, RE386 /
  RLY-53), so the lane's children are torn down and rebuilt by every move — and the browser drops
  the lane scroll body's `scrollTop` to 0 with them. The `PreserveScroll` hook
  (`assets/js/hooks/preserve_scroll.js`) snapshots each lane scroll body's `scrollTop` around a
  LiveView patch and puts it back. `Phoenix.LiveViewTest` never runs JS hooks, so only a real
  browser can see where a lane's `scrollTop` ends up.

  Every drag uses a source and a target that are already in view inside their scroll bodies:
  Playwright's drag scrolls off-screen elements into view itself, which would change `scrollTop`
  and make the assertions meaningless.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    plan = Enum.find(board.stages, &(&1.name == "Plan"))

    %{user: user, board: board, code: code, plan: plan}
  end

  test "dragging a mid-column card out of a scrolled column leaves its scroll position alone", ctx do
    [first | _rest] = column(ctx.board, ctx.code, 20)
    plan_refs = column(ctx.board, ctx.plan, 3)
    code_body = scroll_body(ctx.code.id)

    %{frame_id: frame_id} = session = visit_board(ctx.conn, "/board/#{ctx.board.slug}")

    assert_overflows(frame_id, code_body)
    before = scroll_lane(frame_id, code_body, 0.5)

    refute card_in_body?(frame_id, first, code_body),
           "precondition: #{first} must be scrolled out of view — add cards to the column"

    moved = first_visible_card(frame_id, code_body)

    session
    |> drag(board_card(moved), to: board_card(Enum.at(plan_refs, 1)))
    |> assert_has(in_stage(ctx.plan.id, moved))
    |> refute_has(in_stage(ctx.code.id, moved))

    assert_within(sample_scroll(frame_id, code_body), before, "Code's scroll body after dragging #{moved} out")
  end

  test "dropping a card into a scrolled column leaves its scroll position alone and lands in view", ctx do
    [first | _rest] = column(ctx.board, ctx.plan, 20)
    [moved | _rest] = column(ctx.board, ctx.code, 3)
    plan_body = scroll_body(ctx.plan.id)

    %{frame_id: frame_id} = session = visit_board(ctx.conn, "/board/#{ctx.board.slug}")

    assert_overflows(frame_id, plan_body)
    before = scroll_lane(frame_id, plan_body, 0.5)

    refute card_in_body?(frame_id, first, plan_body),
           "precondition: #{first} must be scrolled out of view — add cards to the column"

    target = first_visible_card(frame_id, plan_body)

    session
    |> drag(board_card(moved), to: board_card(target))
    |> assert_has(in_stage(ctx.plan.id, moved))

    assert_within(sample_scroll(frame_id, plan_body), before, "Plan's scroll body after dropping #{moved} in")
    assert card_in_body?(frame_id, moved, plan_body), "#{moved} landed out of view in Plan's scroll body"
  end

  test "dragging the last card out of a column scrolled to the bottom keeps it at the bottom", ctx do
    column(ctx.board, ctx.code, 20)
    plan_refs = column(ctx.board, ctx.plan, 3)
    code_body = scroll_body(ctx.code.id)

    %{frame_id: frame_id} = session = visit_board(ctx.conn, "/board/#{ctx.board.slug}")

    assert_overflows(frame_id, code_body)
    bottom = scroll_lane(frame_id, code_body, 1)
    assert abs(bottom - overflow(frame_id, code_body)) <= 2, "precondition: Code must start at the very bottom"

    moved = frame_id |> visible_cards(code_body) |> List.last()

    session
    |> drag(board_card(moved), to: board_card(Enum.at(plan_refs, 1)))
    |> assert_has(in_stage(ctx.plan.id, moved))
    |> refute_has(in_stage(ctx.code.id, moved))

    %{"last" => top} = sample_scroll(frame_id, code_body)
    # The column got one card shorter, so the browser clamps scrollTop to the new maximum — that
    # is accepted. Jumping back to the top is not.
    new_bottom = overflow(frame_id, code_body)

    assert abs(top - new_bottom) <= 2,
           "Code's scroll body should stay at the bottom (#{new_bottom}) after dragging #{moved} out, got #{top}"

    assert top > 0, "Code's scroll body jumped back to the top"
  end

  test "a realtime card_moved out of a scrolled column leaves its scroll position alone", ctx do
    [first | _rest] = column(ctx.board, ctx.code, 20)
    column(ctx.board, ctx.plan, 3)
    code_body = scroll_body(ctx.code.id)

    %{frame_id: frame_id} = session = visit_board(ctx.conn, "/board/#{ctx.board.slug}")

    assert_overflows(frame_id, code_body)
    before = scroll_lane(frame_id, code_body, 0.5)

    refute card_in_body?(frame_id, first, code_body),
           "precondition: #{first} must be scrolled out of view — add cards to the column"

    moved = first_visible_card(frame_id, code_body)

    # Another session / the API moves the card: no browser action, only the `card_moved` broadcast.
    {:ok, _moved} = ctx.board |> Cards.get_card_by_ref(moved) |> Cards.move_card(ctx.plan, 0)

    session
    |> refute_has(in_stage(ctx.code.id, moved))
    |> assert_has(in_stage(ctx.plan.id, moved))

    assert_within(sample_scroll(frame_id, code_body), before, "Code's scroll body after a realtime move of #{moved}")
  end

  test "moving a card with the drawer's Move to… menu leaves its source column's scroll position alone", ctx do
    [first | _rest] = column(ctx.board, ctx.code, 20)
    column(ctx.board, ctx.plan, 3)
    code_body = scroll_body(ctx.code.id)

    %{frame_id: frame_id} = session = visit_board(ctx.conn, "/board/#{ctx.board.slug}")

    assert_overflows(frame_id, code_body)
    before = scroll_lane(frame_id, code_body, 0.5)

    refute card_in_body?(frame_id, first, code_body),
           "precondition: #{first} must be scrolled out of view — add cards to the column"

    moved = first_visible_card(frame_id, code_body)

    # Only Code (the source) is asserted on: after the move the drawer may push `scroll_card` for
    # the moved card, which legitimately scrolls Plan to reveal it.
    session
    |> click(board_card(moved))
    |> assert_has("#card-drawer .drawer-card-ref", text: moved, exact: true)
    |> click("#card-drawer-stage-chip")
    |> click("#card-drawer-move-to-#{ctx.plan.id}")
    |> assert_has(in_stage(ctx.plan.id, moved))
    |> refute_has(in_stage(ctx.code.id, moved))

    assert_within(sample_scroll(frame_id, code_body), before, "Code's scroll body after moving #{moved} via Move to…")
  end

  test "dragging a card out of a scrolled sub-lane leaves the sub-lane's scroll position alone", ctx do
    {:ok, review} = Boards.enable_lane(ctx.code, :review)
    [first | _rest] = column(ctx.board, review, 20)
    plan_refs = column(ctx.board, ctx.plan, 3)
    review_body = "#sublane-#{review.id}-cards"

    %{frame_id: frame_id} = session = visit_board(ctx.conn, "/board/#{ctx.board.slug}")

    assert_overflows(frame_id, review_body)
    before = scroll_lane(frame_id, review_body, 0.5)

    refute card_in_body?(frame_id, first, review_body),
           "precondition: #{first} must be scrolled out of view — add cards to the sub-lane"

    moved = first_visible_card(frame_id, review_body)

    session
    |> drag(board_card(moved), to: board_card(Enum.at(plan_refs, 1)))
    |> assert_has(in_stage(ctx.plan.id, moved))
    |> refute_has("#{review_body} #{board_card(moved)}")

    assert_within(sample_scroll(frame_id, review_body), before, "Review sub-lane after dragging #{moved} out")
  end

  # The preserve hook must not undo a deliberate `scroll_card` (RE389): a deep link still reveals
  # its card inside the lane.
  test "a deep link still scrolls its card into view inside the lane", ctx do
    refs = column(ctx.board, ctx.code, 20)
    opened = Enum.at(refs, -2)
    code_body = scroll_body(ctx.code.id)

    %{frame_id: frame_id} = session = visit_board(ctx.conn, "/board/#{ctx.board.slug}")

    assert_overflows(frame_id, code_body)
    assert scroll_lane(frame_id, code_body, 0) == 0, "precondition: Code must start at the top"

    refute card_in_body?(frame_id, opened, code_body),
           "precondition: #{opened} must start below the fold — add cards to the column"

    %{frame_id: frame_id} =
      session
      |> visit("/board/#{ctx.board.slug}?card=#{opened}")
      |> assert_has("body .phx-connected")
      |> assert_has("#card-drawer .drawer-card-ref", text: opened, exact: true)

    _ = Frame.wait_for_function(frame_id, expression: card_in_body_expression(opened, code_body), timeout: 5_000)

    %{"min" => min} = sample_scroll(frame_id, code_body)
    assert min > 0, "Code's scroll body was put back to the top after scroll_card revealed #{opened}"
    assert card_in_body?(frame_id, opened, code_body), "#{opened} was never scrolled into view in Code's scroll body"
  end

  defp assert_within(%{"min" => min, "max" => max} = sample, expected, what) do
    assert abs(min - expected) <= 2 and abs(max - expected) <= 2,
           "#{what}: scrollTop moved from #{expected} to #{inspect(sample)} (want within 2px)"
  end

  # scrollHeight - clientHeight: the largest scrollTop the lane can have.
  defp overflow(frame_id, selector) do
    {:ok, overflow} =
      Frame.evaluate(frame_id,
        expression: "(el => el.scrollHeight - el.clientHeight)(document.querySelector(#{Jason.encode!(selector)}))",
        timeout: 2_000
      )

    overflow
  end

  defp assert_overflows(frame_id, selector) do
    overflow = overflow(frame_id, selector)

    # Precondition: if the lane doesn't overflow, "kept its scroll position" proves nothing. If
    # this fails, the column needs more cards, not a looser assertion.
    assert overflow > 200, "precondition: #{selector} must overflow by >200px, got #{overflow} — add cards"
  end

  # Creates `count` cards in `stage` and returns their refs in the order the board renders the
  # column (`Cards.stage_column/2` is the board's own read).
  defp column(board, stage, count) do
    Enum.each(1..count, fn n -> {:ok, _card} = Cards.create_card(stage, %{title: "Scroll #{n}"}) end)

    board |> Cards.stage_column(stage.id) |> Enum.map(&Cards.ref(board, &1))
  end

  # The stage's main-lane scroll body (`#stage-col-<position>-scroll`), addressed through the
  # column so the test doesn't hard-code a stage position.
  defp scroll_body(stage_id), do: ~s(.stage-column[data-stage-id="#{stage_id}"] [id$="-scroll"])

  # Scrolls `selector` to `fraction` of its overflow, lets layout and scroll events settle for a
  # few animation frames, and returns the resulting scrollTop.
  defp scroll_lane(frame_id, selector, fraction) do
    {:ok, top} =
      Frame.evaluate(frame_id,
        expression: """
        (async () => {
          const el = document.querySelector(#{Jason.encode!(selector)});
          el.scrollTop = #{fraction} * (el.scrollHeight - el.clientHeight);
          for (let i = 0; i < 4; i++) await new Promise(r => requestAnimationFrame(r));
          return el.scrollTop;
        })()
        """,
        timeout: 5_000
      )

    top
  end

  # Samples `selector`'s scrollTop once per animation frame for `frames` frames. The acting
  # session patches twice per move (its own reply, then its `card_moved` echo), so a single read
  # right after the first patch could miss the second.
  defp sample_scroll(frame_id, selector, frames \\ 30) do
    {:ok, sample} =
      Frame.evaluate(frame_id,
        expression: """
        (async () => {
          const seen = [];
          for (let i = 0; i < #{frames}; i++) {
            await new Promise(r => requestAnimationFrame(r));
            seen.push(document.querySelector(#{Jason.encode!(selector)}).scrollTop);
          }
          return {min: Math.min(...seen), max: Math.max(...seen), last: seen[seen.length - 1]};
        })()
        """,
        timeout: 10_000
      )

    sample
  end

  # Refs of the cards whose rects lie wholly inside the scroll body's rect, top to bottom.
  defp visible_cards(frame_id, selector) do
    {:ok, refs} =
      Frame.evaluate(frame_id,
        expression: """
        (() => {
          const body = document.querySelector(#{Jason.encode!(selector)});
          const b = body.getBoundingClientRect();
          return Array.from(body.querySelectorAll(".board-card"))
            .filter(c => { const r = c.getBoundingClientRect(); return r.top >= b.top && r.bottom <= b.bottom; })
            .map(c => c.dataset.ref);
        })()
        """,
        timeout: 2_000
      )

    refs
  end

  # True once `ref`'s rect lies wholly inside the scroll body's rect.
  defp card_in_body_expression(ref, selector) do
    "(() => { const b = document.querySelector(#{Jason.encode!(selector)}).getBoundingClientRect();" <>
      " const c = document.querySelector(#{Jason.encode!(board_card(ref))});" <>
      " if (!c) return false; const r = c.getBoundingClientRect();" <>
      " return r.top >= b.top && r.bottom <= b.bottom; })()"
  end

  defp first_visible_card(frame_id, selector), do: frame_id |> visible_cards(selector) |> List.first()

  defp card_in_body?(frame_id, ref, selector), do: ref in visible_cards(frame_id, selector)

  defp visit_board(conn, path) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit(path)
    # A push to a hook that hasn't mounted yet is lost, so wait for THIS page's socket.
    |> assert_has("body .phx-connected")
  end

  defp board_card(ref), do: ~s(.board-card[data-ref="#{ref}"])

  defp in_stage(stage_id, ref), do: ~s(.stage-column[data-stage-id="#{stage_id}"] #{board_card(ref)})
end
