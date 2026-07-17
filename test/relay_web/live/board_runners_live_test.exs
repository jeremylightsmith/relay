defmodule RelayWeb.BoardRunnersLiveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.AgentLog
  alias Relay.Boards
  alias Relay.RunnerPresence

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  defp payload(runner_id, overrides \\ %{}) do
    Map.merge(
      %{
        "runner_id" => runner_id,
        "host" => "test-host",
        "started_at" => "2026-07-17T08:00:00Z",
        "interval" => 30,
        "pools" => [%{"name" => "clean", "mode" => "shared", "used" => 1, "total" => 3}],
        "jobs" => [
          %{"ref" => "RLY-1", "stage" => "Code", "pool" => "clean", "started_at" => "2026-07-17T08:01:00Z"}
        ],
        "refs" => ["RLY-1"]
      },
      overrides
    )
  end

  test "a beat renders the runner panel live — FRESH pill, capacity pips, summary chip",
       %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")
    refute has_element?(view, "#runner-r1")

    RunnerPresence.beat(board.id, payload("r1"))

    assert has_element?(view, "#runner-r1")
    assert has_element?(view, "#runner-r1 .badge-success", "FRESH")
    assert has_element?(view, "#runner-r1", "test-host")
    assert has_element?(view, "#runner-r1-pool-clean", "1/3")
    assert has_element?(view, "#summary-fresh", "1 online")
  end

  test "an idle runner reads connected with WORKING NOW · 0", %{conn: conn, board: board} do
    RunnerPresence.beat(board.id, payload("r1", %{"jobs" => [], "refs" => []}))
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    assert has_element?(view, "#runner-r1 .badge-success", "FRESH")
    assert has_element?(view, "#runner-r1", "WORKING NOW · 0")
    refute has_element?(view, "#runner-r1-at-risk")
  end

  test "two runners are two panels, each owning only its jobs", %{conn: conn, board: board} do
    RunnerPresence.beat(board.id, payload("r1"))

    RunnerPresence.beat(
      board.id,
      payload("r2", %{
        "started_at" => "2026-07-17T09:00:00Z",
        "jobs" => [%{"ref" => "RLY-2", "stage" => "Spec", "pool" => "work", "started_at" => "2026-07-17T09:01:00Z"}],
        "refs" => ["RLY-2"]
      })
    )

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    assert has_element?(view, "#runner-r1-job-RLY-1")
    refute has_element?(view, "#runner-r1-job-RLY-2")
    assert has_element?(view, "#runner-r2-job-RLY-2")
    refute has_element?(view, "#runner-r2-job-RLY-1")
  end

  test "a job row shows stage + pool chip and links the ref to the card drawer URL",
       %{conn: conn, board: board} do
    RunnerPresence.beat(board.id, payload("r1"))
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    assert has_element?(view, "#runner-r1-job-RLY-1", "Code")
    assert has_element?(view, "#runner-r1-job-RLY-1", "clean")
    assert has_element?(view, ~s|#runner-r1-job-RLY-1 a[href="/board/#{board.slug}?card=RLY-1"]|, "RLY-1")
  end

  test "agent log lines land only under the runner whose latest beat claimed the ref",
       %{conn: conn, board: board} do
    RunnerPresence.beat(board.id, payload("r1"))

    RunnerPresence.beat(
      board.id,
      payload("r2", %{"started_at" => "2026-07-17T09:00:00Z", "jobs" => [], "refs" => ["RLY-2"]})
    )

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    AgentLog.record(board.id, [%{"ref" => "RLY-1", "kind" => "claude", "text" => "hello r1"}])

    assert has_element?(view, "#runner-r1-log", "hello r1")
    refute has_element?(view, "#runner-r2-log", "hello r1")
    # the artboard's dark terminal treatment (line ~243)
    assert render(element(view, "#runner-r1-log")) =~ "oklch(0.19 0.02 255)"
  end

  test "unclaimed-ref and ref-less lines render nowhere on this page", %{conn: conn, board: board} do
    RunnerPresence.beat(board.id, payload("r1"))
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    AgentLog.record(board.id, [
      %{"ref" => "RLY-999", "kind" => "claude", "text" => "orphan line"},
      %{"kind" => "lifecycle", "text" => "board-level line"}
    ])

    html = render(view)
    refute html =~ "orphan line"
    refute html =~ "board-level line"
  end

  test "a silent runner renders STALE with the at-risk note, then GONE with ORPHANED JOB",
       %{conn: conn, board: board} do
    now = DateTime.utc_now()
    RunnerPresence.beat(board.id, payload("r1"), DateTime.add(now, -50, :second))
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    assert has_element?(view, "#runner-r1 .badge-warning", "STALE")
    assert has_element?(view, "#runner-r1", "AT-RISK JOB")
    assert render(element(view, "#runner-r1-at-risk")) =~ "exclusive runs park"

    RunnerPresence.beat(board.id, payload("r1"), DateTime.add(now, -70, :second))
    send(view.pid, :tick)

    assert has_element?(view, "#runner-r1 .badge-error", "GONE")
    assert has_element?(view, "#runner-r1", "ORPHANED JOB")
  end

  test "the tick reflects prunes without a reload", %{conn: conn, board: board} do
    RunnerPresence.beat(board.id, payload("r1"), DateTime.add(DateTime.utc_now(), -25, :hour))
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")
    assert has_element?(view, "#runner-r1")

    RunnerPresence.prune(DateTime.utc_now())
    send(view.pid, :tick)

    refute has_element?(view, "#runner-r1")
    assert has_element?(view, "#runners-empty")
  end

  test "with no runners the empty state names the real start command", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    assert has_element?(view, "#runners-empty", "No runners connected")
    assert has_element?(view, "#runner-start-command", "bin/relay watch")
    assert has_element?(view, "#copy-start-command")
    assert has_element?(view, "#runners-empty", "Waiting for a heartbeat…")
    # deliberate deviation from the artboard: the real command, not npx relay-runner
    refute render(view) =~ "npx relay-runner"
  end

  test "board settings gains an ENGINE rail group linking to runners", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

    assert has_element?(view, "#settings-rail", "ENGINE")
    assert has_element?(view, ~s|#settings-nav-runners[href="/board/#{board.slug}/runners"]|, "Runners")
    assert has_element?(view, "#settings-tab-runners")
  end
end
