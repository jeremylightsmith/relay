defmodule HamacaWeb.Browser.EmbedBoardStageRestoreTest do
  @moduledoc """
  Real-browser (Playwright) test for RE452: `/board/<slug>?embed=1&stage=<id>` opens the
  phone-width pager on that stage page (a sub-lane id resolves to its parent's page), and the
  BoardPager hook reports the showing page (`relayStageChanged`) and an id that is not on the
  board (`relayStageMissing`) to the native shell. Only a real browser runs the hook, the
  pager round-trip and the scroll.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias Hamaca.Accounts
  alias Hamaca.Boards
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Frame

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 390, height: 844}]

  # Installed before any page script, so the stub exists when the hook mounts.
  @stub "window.__calls = []; window.flutter_inappwebview = {callHandler: (...a) => window.__calls.push(a)};"

  # Records uncaught page errors — the plain-browser case must raise none.
  @error_trap """
  window.__errors = [];
  window.addEventListener("error", e => window.__errors.push(String(e.message)));
  window.addEventListener("unhandledrejection", e => window.__errors.push(String(e.reason)));
  """

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    top = fn name -> Enum.find(board.stages, &(is_nil(&1.parent_id) and &1.name == name)) end
    spec = top.("Spec")
    spec_review = Enum.find(board.stages, &(&1.parent_id == spec.id and &1.type == :review))

    %{board: board, backlog: top.("Backlog"), code: top.("Code"), spec: spec, spec_review: spec_review}
  end

  defp init_script(conn, source) do
    {:ok, _} = BrowserContext.add_init_script(conn.context_id, source: source, timeout: 2_000)
    conn
  end

  defp measure(conn, expression) do
    parent = self()

    unwrap(conn, fn %{frame_id: frame_id} ->
      {:ok, value} = Frame.evaluate(frame_id, expression: expression, timeout: 2_000)
      send(parent, {:measured, value})
    end)

    assert_received {:measured, value}
    value
  end

  # Waits for a JS condition; on a timeout the assertion that follows reports what is there.
  defp await_js(conn, expression) do
    unwrap(conn, fn %{frame_id: frame_id} ->
      _ = Frame.wait_for_function(frame_id, expression: expression, timeout: 5_000)
    end)
  end

  # The pager round-trip has landed: the empty (collapsed) Backlog renders as a compact page
  # only once the server has @pager_mode on, which is when the `?stage=` restore runs.
  defp await_pager(conn, backlog) do
    unwrap(conn, fn %{frame_id: frame_id} ->
      {:ok, _} =
        Frame.wait_for_selector(frame_id,
          selector: ~s(.stage-column.stage-compact[data-stage-id="#{backlog.id}"]),
          state: "attached",
          timeout: 5_000
        )
    end)
  end

  defp visit_board(conn, query) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{query}")
    |> assert_has("body .phx-connected")
  end

  defp calls(conn), do: measure(conn, "window.__calls")

  defp missing_calls(conn), do: Enum.filter(calls(conn), &match?(["relayStageMissing" | _], &1))

  test "2. ?stage= opens the pager on that stage and reports it", %{conn: conn} = ctx do
    %{board: board, code: code} = ctx

    conn =
      conn
      |> init_script(@stub)
      |> visit_board("#{board.slug}?embed=1&stage=#{code.id}")
      |> assert_has("#stage-chip-#{code.id}[data-active]")

    page = ~s|document.querySelector('.stage-column[data-stage-id="#{code.id}"]')|
    bands = ~s|document.querySelector('#board-bands')|
    gap = "Math.abs(#{page}.getBoundingClientRect().left - #{bands}.getBoundingClientRect().left)"
    await_js(conn, "#{gap} <= 1")

    assert measure(conn, gap) <= 1

    assert ["relayStageChanged", %{"board" => board.slug, "stage_id" => code.id, "stage_name" => "Code"}] in calls(conn)
  end

  test "3. a sub-lane id opens its parent's page, and is not missing", %{conn: conn} = ctx do
    %{board: board, backlog: backlog, spec: spec, spec_review: spec_review} = ctx

    conn =
      conn
      |> init_script(@stub)
      |> visit_board("#{board.slug}?embed=1&stage=#{spec_review.id}")
      |> assert_has("#stage-chip-#{spec.id}[data-active]")

    await_pager(conn, backlog)

    assert missing_calls(conn) == []
  end

  test "4. an id not on the board stays on the first stage and reports it missing once",
       %{conn: conn} = ctx do
    %{board: board, backlog: backlog} = ctx

    conn =
      conn
      |> init_script(@stub)
      |> visit_board("#{board.slug}?embed=1&stage=999999")

    await_pager(conn, backlog)
    await_js(conn, ~s|window.__calls.some(c => c[0] === "relayStageMissing")|)

    assert_has(conn, "#stage-chip-#{backlog.id}[data-active]")
    assert missing_calls(conn) == [["relayStageMissing", %{"stage_id" => 999_999}]]
  end

  test "5. no ?stage= keeps the default first stage and reports nothing missing",
       %{conn: conn} = ctx do
    %{board: board, backlog: backlog} = ctx

    conn =
      conn
      |> init_script(@stub)
      |> visit_board("#{board.slug}?embed=1")
      |> assert_has("#stage-chip-#{backlog.id}[data-active]")

    await_pager(conn, backlog)

    assert missing_calls(conn) == []
  end

  test "6. a plain browser (no native bridge) restores the stage without a JS error",
       %{conn: conn} = ctx do
    %{board: board, code: code} = ctx

    conn =
      conn
      |> init_script(@error_trap)
      |> visit_board("#{board.slug}?stage=#{code.id}")
      |> assert_has("#stage-chip-#{code.id}[data-active]")

    assert measure(conn, "typeof window.flutter_inappwebview") == "undefined"
    assert measure(conn, "window.__errors") == []
  end

  # The native shell re-applies the stage when a board that loaded under a pushed card is
  # revealed (its one-shot restore ran hidden and drifted) — a sub-lane id resolves too.
  test "7. relay:show-stage re-shows that stage page after the pager drifted", %{conn: conn} = ctx do
    %{board: board, backlog: backlog, code: code, spec: spec, spec_review: spec_review} = ctx

    conn =
      conn
      |> init_script(@stub)
      |> visit_board("#{board.slug}?embed=1&stage=#{code.id}")
      |> assert_has("#stage-chip-#{code.id}[data-active]")

    await_pager(conn, backlog)

    # Drift: the page ends up somewhere else.
    measure(
      conn,
      ~s|document.querySelector('.stage-column[data-stage-id="#{backlog.id}"]').scrollIntoView({behavior: "instant", inline: "start"}), true|
    )

    assert_has(conn, "#stage-chip-#{backlog.id}[data-active]")

    measure(
      conn,
      ~s|window.dispatchEvent(new CustomEvent("relay:show-stage", {detail: {stage_id: #{code.id}}})), true|
    )

    assert_has(conn, "#stage-chip-#{code.id}[data-active]")

    measure(
      conn,
      ~s|window.dispatchEvent(new CustomEvent("relay:show-stage", {detail: {stage_id: #{spec_review.id}}})), true|
    )

    assert_has(conn, "#stage-chip-#{spec.id}[data-active]")
    assert ["relayStageChanged", %{"board" => board.slug, "stage_id" => spec.id, "stage_name" => "Spec"}] in calls(conn)
  end
end
