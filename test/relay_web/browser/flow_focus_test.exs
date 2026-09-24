defmodule RelayWeb.Browser.FlowFocusTest do
  @moduledoc """
  Real-browser (Playwright) test for RE333's hover emphasis. The `FlowFocus` hook is pure
  client-side JS — it never talks to the server — so a LiveView test cannot see it; only a real
  pointer over a real node exercises it.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards

  @moduletag :playwright

  setup do
    user = Accounts.ensure_dev_user!()
    %{board: Boards.get_or_create_default_board(user)}
  end

  defp open_code_flow(conn, board) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}/flows/code")
    |> assert_has("#flow-graph")
    # The hook mounts on connect; a hover before then would land on an un-hooked graph. Wait for
    # the connected socket on THIS page (the earlier one was /dev/login's).
    |> assert_has("body .phx-connected")
  end

  defp eval!(frame_id, js) do
    {:ok, value} = Frame.evaluate(frame_id, expression: "(() => #{js})()", timeout: 2_000)
    value
  end

  # The drawn Code flow edges touching quality_review, as a sorted comma-joined index string.
  defp incident(key) do
    flow = Enum.find(Relay.Flows.DefaultLibrary.all(), &(&1.key == "code"))

    flow.edges
    |> Enum.with_index()
    |> Enum.filter(fn {e, _i} -> e.to != "needs_input" and key in [e.from, e.to] end)
    |> Enum.map_join(",", &elem(&1, 1))
  end

  defp hot(frame_id, attr) do
    eval!(
      frame_id,
      ~s|[...document.querySelectorAll("#flow-graph [#{attr}][data-hot]")].map(el => Number(el.getAttribute("#{attr}"))).sort((a, b) => a - b).join(",")|
    )
  end

  test "hovering a node emphasises its edges; leaving clears the emphasis", %{conn: conn, board: board} do
    conn
    |> open_code_flow(board)
    |> refute_has("#flow-graph[data-dim]")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.hover(frame_id, selector: ~s([data-node="quality_review"]), timeout: 2_000)
    end)
    |> assert_has(~s(#flow-graph[data-dim="hover"]))
    |> unwrap(fn %{frame_id: frame_id} ->
      expected = incident("quality_review")
      assert expected != ""
      assert hot(frame_id, "data-edge-path") == expected
      assert hot(frame_id, "data-edge") == expected

      assert eval!(
               frame_id,
               ~s|[...document.querySelectorAll("#flow-graph [data-edge]:not([data-hot])")].every(el => getComputedStyle(el).visibility === "hidden")|
             ),
             "an edge label not touching quality_review is still visible while it is hovered"

      assert eval!(
               frame_id,
               ~s|[...document.querySelectorAll("#flow-graph [data-edge][data-hot]")].every(el => getComputedStyle(el).visibility === "visible")|
             ),
             "a label on one of quality_review's own edges was hidden"
    end)
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.hover(frame_id, selector: "#flow-title", timeout: 2_000)
    end)
    |> refute_has("#flow-graph[data-dim]")
    |> unwrap(fn %{frame_id: frame_id} ->
      assert eval!(frame_id, ~s|document.querySelectorAll("#flow-graph [data-hot]").length|) == 0
    end)
  end
end
