defmodule RelayWeb.Browser.BoardCollapsedPagerTest do
  @moduledoc """
  Real-browser (Playwright) regression test for RE377: at phone width a collapsed
  stage stays collapsed in the pager, rendered as a compact page of one-line rows.

  Two things only a real browser proves: the BoardPager hook's `pager` round-trip
  actually restreams the collapsed stage's cards (the page used to be empty — the
  desktop strip has no stream container, so its cards were consumed and dropped),
  and a long title truncates onto one ellipsised line instead of wrapping the row.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 390, height: 844}]

  @long_title "A very long card title that must never wrap onto a second line in the " <>
                "compact row list of a collapsed stage page on a phone-width screen"

  test "a collapsed stage's page lists its cards as one-line truncated rows", %{conn: conn} do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, code} = Boards.update_stage(code, %{collapsed_by_default: true})
    {:ok, _} = Cards.create_card(code, %{title: @long_title})
    {:ok, _} = Cards.create_card(code, %{title: "Short one"})

    col = "stage-col-#{code.position}"

    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}")
    |> assert_has("body .phx-connected")
    |> assert_has(~s(#stage-chip-#{code.id}[data-collapsed="true"]))
    |> click("#stage-chip-#{code.id}")
    # assert_has auto-waits for the pager round-trip to restream the rows.
    |> assert_has("##{col}.stage-compact[data-collapsed='true']")
    |> assert_has("##{col}-rows .compact-card-row", count: 2)
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, m} =
        Frame.evaluate(frame_id,
          expression: """
          (() => {
            const rows = [...document.querySelectorAll('##{col}-rows .compact-card-row')];
            const row = rows.find((r) => r.textContent.includes('A very long card title'));
            const title = row.querySelector('.compact-card-row-title');
            const cs = getComputedStyle(title);
            const lineHeight = parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.5;
            return {
              rows: rows.length,
              rowHeight: row.getBoundingClientRect().height,
              titleHeight: title.getBoundingClientRect().height,
              lineHeight: lineHeight,
              overflowing: title.scrollWidth > title.clientWidth,
              textOverflow: cs.textOverflow,
              whiteSpace: cs.whiteSpace
            };
          })()
          """,
          timeout: 2_000
        )

      assert m["rows"] == 2, "the collapsed stage's page should list both cards as rows"

      assert m["whiteSpace"] == "nowrap" and m["textOverflow"] == "ellipsis",
             "row title should truncate (nowrap + ellipsis), got #{inspect(m)}"

      assert m["overflowing"],
             "the long title should overflow its one line (and be ellipsised), got #{inspect(m)}"

      assert m["titleHeight"] <= m["lineHeight"] + 1,
             "row title wrapped past one line: #{inspect(m)}"

      # min-h-11 = 44px; a wrapped title would grow the row past it.
      assert m["rowHeight"] <= 45, "the row grew past its 44px one-line height: #{inspect(m)}"
    end)
  end
end
