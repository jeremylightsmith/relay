defmodule RelayWeb.Browser.DoneShowMoreTest do
  @moduledoc """
  Real-browser (Playwright) regression test for RLY-53.

  The "Show N more" button shipped inside the Done lane's scroll container, as
  a sibling after the `#...-cards` div. That div carries `min-height:100%`
  (RLY-1's full-height drop zone), so it fills the scroll viewport however few
  cards it holds — pinning the button just past the bottom edge: a 3px sliver,
  45px of scrolling away, below a tall blank drop zone. The button was in the
  DOM the entire time, so `has_element?/2` and the element counts in
  `board_live_done_limit_test.exs` all passed while no user could see it.
  Geometry in a real browser is the only honest assertion here.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright

  test "the Show more button is visible inside the Done column", %{conn: conn} do
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
            const col = btn.closest('.stage-column');
            const b = btn.getBoundingClientRect(), c = col.getBoundingClientRect();
            return {
              belowColumn: Math.round(b.bottom - c.bottom),
              height: Math.round(b.height),
              inScroller: btn.closest('[id$="-scroll"]') ? 1 : 0
            };
          })()
          """,
          timeout: 2_000
        )

      # The button lies fully within the column's visible box — not clipped off
      # the bottom edge by the full-height drop zone.
      assert box["belowColumn"] <= 0,
             "the Show more button sits #{box["belowColumn"]}px below the Done " <>
               "column's visible area, where no user can see it"

      assert box["height"] > 0, "the Show more button has no height"

      # …because it is a pinned footer, not trapped in the scrolling area.
      assert box["inScroller"] == 0,
             "the Show more button is inside the lane's scroll container"
    end)
  end
end
