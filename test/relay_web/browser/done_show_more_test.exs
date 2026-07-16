defmodule RelayWeb.Browser.DoneShowMoreTest do
  @moduledoc """
  Real-browser (Playwright) regression test for the Done "Show N more" button.

  RLY-53 pinned the button as a column footer outside the lane scroller;
  RLY-116 reverses that: the `.stage-drop` wrapper owns the stretched drop
  zone (RLY-1) while the `.stage-cards` list is natural-height, so the button
  flows directly after the last card inside the scroller (~263px of dead
  space -> the lane's normal 8px flex gap). With many cards revealed the
  button may sit below the lane's fold — intended; scrolling the lane reaches
  it. Geometry in a real browser is the only honest assertion here.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright

  test "the Show more button flows right after the last Done card", %{conn: conn} do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    done = Boards.terminal_stage(board.stages)

    # 12 Done cards -> newest 8 rendered, 4 hidden, so the button must render.
    for i <- 1..12 do
      {:ok, _card} = Cards.create_card(done, %{title: "Done #{i}"})
    end

    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}")
    # assert_has waits for the button to be in the DOM; evaluate below does not
    # auto-wait and would otherwise read a null element.
    |> assert_has("#stage-col-#{done.position}-show-more-done")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, box} =
        Frame.evaluate(frame_id,
          expression: """
          (() => {
            const btn = document.querySelector('#stage-col-#{done.position}-show-more-done');
            btn.scrollIntoView({block: 'nearest'});
            const cards = document.querySelectorAll('#stage-col-#{done.position}-cards .board-card');
            const last = cards[cards.length - 1];
            const col = btn.closest('.stage-column');
            const b = btn.getBoundingClientRect(), c = col.getBoundingClientRect();
            return {
              gap: Math.round(b.top - last.getBoundingClientRect().bottom),
              belowColumn: Math.round(b.bottom - c.bottom),
              height: Math.round(b.height),
              inScroller: btn.closest('[id$="-scroll"]') ? 1 : 0
            };
          })()
          """,
          timeout: 2_000
        )

      # The button flows right after the last card (the lane's normal 8px
      # flex gap), not ~263px below it at the bottom of a stretched drop zone.
      assert box["gap"] >= 0 and box["gap"] <= 24,
             "expected the Show more button ~8px after the last card, got #{box["gap"]}px"

      assert box["height"] > 0, "the Show more button has no height"

      # It flows inside the lane scroller now (not a pinned footer), and after
      # scrolling the lane to it, it is fully visible within the column.
      assert box["inScroller"] == 1,
             "the Show more button should flow inside the lane's scroll container"

      assert box["belowColumn"] <= 0,
             "the Show more button sits #{box["belowColumn"]}px below the Done " <>
               "column's visible area even after scrolling the lane to it"
    end)
  end
end
