defmodule RelayWeb.Browser.TalkAutoscrollTest do
  @moduledoc """
  RE301 — real-browser (Playwright) test for the Talk pane's stick-to-bottom autoscroll.

  Scroll position only exists in a real layout engine: `Phoenix.LiveViewTest` never runs the
  `.TalkAutoscroll` hook, so none of this is visible to a LiveView test. New lines arrive the
  production way, through `Relay.Talk.append_events/2`, which broadcasts `{:talk_event, _}` to
  the open drawer.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Talk

  @moduletag :playwright

  # Enough 19px lines to overflow the 548px pane several times over.
  @backlog 60

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: "Long talk"})

    {:ok, turn} = Talk.post_message(card, user, "what happened?")
    {:ok, _} = Talk.append_events(turn, Enum.map(1..@backlog, &line(&1, "backlog line #{&1}")))

    %{board: board, card: card, turn: turn}
  end

  defp line(client_seq, text), do: %{"client_seq" => client_seq, "kind" => "out", "text" => text, "dim" => false}

  defp append(turn, client_seq, text) do
    {:ok, [_]} = Talk.append_events(turn, [line(client_seq, text)])
  end

  defp open_talk(conn, board, card) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}?card=#{board.key}#{card.ref_number}")
    |> assert_has("#card-drawer-panel")
    |> assert_has("body .phx-connected")
    |> click("#card-drawer-tab-talk")
    |> assert_has("#card-drawer-tab-talk[data-active='true']")
    |> assert_has("#talk-pane-transcript", text: "backlog line #{@backlog}")
  end

  # Waits a few animation frames (so observers, the scroll event and layout have all run), then
  # reads the scroll body's geometry. `gap` is how far the view sits above the very bottom.
  defp geometry(frame_id) do
    {:ok, geo} =
      Frame.evaluate(frame_id,
        expression: """
        (async () => {
          for (let i = 0; i < 4; i++) await new Promise(r => requestAnimationFrame(r));
          const el = document.getElementById("talk-pane-scroll");
          return {top: el.scrollTop, gap: el.scrollHeight - el.scrollTop - el.clientHeight,
                  overflow: el.scrollHeight - el.clientHeight};
        })()
        """,
        timeout: 5_000
      )

    geo
  end

  defp scroll_to(frame_id, where) do
    target = if where == :top, do: "0", else: "el.scrollHeight"

    {:ok, _} =
      Frame.evaluate(frame_id,
        expression: """
        (async () => {
          const el = document.getElementById("talk-pane-scroll");
          el.scrollTop = #{target};
          for (let i = 0; i < 4; i++) await new Promise(r => requestAnimationFrame(r));
          return true;
        })()
        """,
        timeout: 5_000
      )
  end

  defp assert_at_bottom(frame_id, why) do
    geo = geometry(frame_id)
    assert geo["overflow"] > 100, "the transcript never overflowed the pane (#{inspect(geo)})"
    assert geo["gap"] <= 2, "#{why}: the pane is not at the bottom (#{inspect(geo)})"
  end

  test "Talk opens at the bottom, follows new output, and stops following when scrolled up", ctx do
    ctx.conn
    |> open_talk(ctx.board, ctx.card)
    |> unwrap(fn %{frame_id: frame_id} -> assert_at_bottom(frame_id, "on opening Talk") end)
    |> tap(fn _ -> append(ctx.turn, @backlog + 1, "fresh line one") end)
    |> assert_has("#talk-pane-transcript", text: "fresh line one")
    |> unwrap(fn %{frame_id: frame_id} ->
      assert_at_bottom(frame_id, "after a new line arrived while stuck")
      scroll_to(frame_id, :top)
      assert geometry(frame_id)["top"] == 0
    end)
    |> tap(fn _ -> append(ctx.turn, @backlog + 2, "fresh line two") end)
    |> assert_has("#talk-pane-transcript", text: "fresh line two")
    |> unwrap(fn %{frame_id: frame_id} ->
      assert geometry(frame_id)["top"] == 0,
             "a new line yanked the view down although the user had scrolled up to read"

      scroll_to(frame_id, :bottom)
    end)
    |> tap(fn _ -> append(ctx.turn, @backlog + 3, "fresh line three") end)
    |> assert_has("#talk-pane-transcript", text: "fresh line three")
    |> unwrap(fn %{frame_id: frame_id} ->
      assert_at_bottom(frame_id, "after scrolling back down, following should resume")
    end)
  end

  # The pane stays rendered under a `hidden` tab panel, and `display:none` resets scrollTop to 0,
  # so re-entering Talk must land at the bottom again even though the user left it scrolled up.
  test "coming back to the Talk tab lands at the bottom again", ctx do
    ctx.conn
    |> open_talk(ctx.board, ctx.card)
    |> unwrap(fn %{frame_id: frame_id} -> scroll_to(frame_id, :top) end)
    |> click("#card-drawer-tab-detail")
    |> assert_has("#card-drawer-tab-detail[data-active='true']")
    |> click("#card-drawer-tab-talk")
    |> assert_has("#card-drawer-tab-talk[data-active='true']")
    |> assert_has("#talk-pane-transcript", text: "backlog line #{@backlog}")
    |> unwrap(fn %{frame_id: frame_id} -> assert_at_bottom(frame_id, "on re-entering Talk") end)
  end
end
