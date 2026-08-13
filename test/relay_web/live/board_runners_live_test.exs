defmodule RelayWeb.BoardRunnersLiveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.AgentLog
  alias Relay.Boards

  setup :register_and_log_in_user

  setup %{user: user} do
    start_capacity!()
    board = Boards.get_or_create_default_board(user)

    # Reuse one of the board's OWN stages rather than inserting another. The default board
    # already ships stages at positions 1..11, while `insert(:stage, ...)` draws `position`
    # from a globally-shared ExMachina sequence that starts at 1 — so it collides on
    # stages_board_id_position_index unless some earlier test file has already advanced the
    # sequence past 11. That made this file pass in the full suite and fail 11/13 standalone
    # (caught by the RLY-167 spec review). The tests only need somewhere to put a card.
    %{board: board, stage: List.first(board.stages)}
  end

  defp executor(board, name, overrides \\ []) do
    insert(:executor, [board: board, name: name] ++ overrides)
  end

  defp active_job(stage, executor_name, opts \\ []) do
    card = insert(:card, stage: stage, title: opts[:title] || "Ship the thing")
    run = insert(:run, card: card)
    ne = insert(:node_execution, run: run, node_key: opts[:node_key] || "implement")

    job =
      insert(:node_job,
        node_execution: ne,
        executor_name: executor_name,
        state: opts[:state] || :claimed,
        payload: %{"isolation" => opts[:isolation] || "shared_clean"}
      )

    %{card: card, job: job}
  end

  # A queued, unclaimed job on this board, inserted `age_s` ago.
  defp queued_job(stage, opts \\ []) do
    at = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -(opts[:age_s] || 0), :second)
    card = insert(:card, stage: stage, title: opts[:title] || "Ship the thing")
    run = insert(:run, card: card, flow_key: "code")
    ne = insert(:node_execution, run: run, node_key: opts[:node_key] || "implement", inserted_at: at)

    job =
      insert(:node_job,
        node_execution: ne,
        state: :queued,
        executor_name: nil,
        claimed_at: nil,
        inserted_at: at,
        payload: %{"isolation" => opts[:isolation] || "shared_clean"}
      )

    %{card: card, job: job}
  end

  defp ref(board, card), do: "#{board.key}#{card.ref_number}"

  test "a heartbeating executor renders by name with its capacity chips and FRESH pill",
       %{conn: conn, board: board} do
    executor(board, "mac-mini", host: "mac-mini.local", capacity: %{"shared_clean" => 3, "exclusive" => 1})

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    assert has_element?(view, "#runner-mac-mini")
    assert has_element?(view, "#runner-mac-mini .badge-success", "FRESH")
    assert has_element?(view, "#runner-mac-mini", "mac-mini.local")
    assert has_element?(view, "#runner-mac-mini-pool-shared_clean", "0/3")
    assert has_element?(view, "#runner-mac-mini-pool-exclusive", "0/1")
    assert has_element?(view, "#summary-fresh", "1 online")
    # artboard lines ~84-97 / capChip ~176-187: an under-capacity chip is the green treatment
    assert render(element(view, "#runner-mac-mini-pool-shared_clean")) =~
             "color-mix(in oklab, var(--color-success) 25%, var(--color-base-100))"
  end

  test "an idle fresh executor reads WORKING NOW · 0 with no at-risk note",
       %{conn: conn, board: board} do
    executor(board, "mac-mini")
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    assert has_element?(view, "#runner-mac-mini", "WORKING NOW · 0")
    refute has_element?(view, "#runner-mac-mini-at-risk")
  end

  test "an in-flight job is attributed to its executor with card ref and node key",
       %{conn: conn, board: board, stage: stage} do
    executor(board, "mac-mini", capacity: %{"shared_clean" => 3})
    %{card: card, job: job} = active_job(stage, "mac-mini", node_key: "implement")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    assert has_element?(view, "#runner-mac-mini-job-#{job.id}", ref(board, card))
    assert has_element?(view, "#runner-mac-mini-job-#{job.id}", "implement")
    assert has_element?(view, "#runner-mac-mini-job-#{job.id}", "Ship the thing")

    assert has_element?(
             view,
             ~s|#runner-mac-mini-job-#{job.id} a[href="/board/#{board.slug}?card=#{ref(board, card)}"]|
           )

    # the job consumes a slot in its advertised pool
    assert has_element?(view, "#runner-mac-mini-pool-shared_clean", "1/3")
    assert has_element?(view, "#runner-mac-mini", "WORKING NOW · 1")
  end

  test "two executors are two panels, each owning only its own jobs",
       %{conn: conn, board: board, stage: stage} do
    executor(board, "mac-a")
    executor(board, "mac-b")
    %{job: job_a} = active_job(stage, "mac-a")
    %{job: job_b} = active_job(stage, "mac-b")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    assert has_element?(view, "#runner-mac-a-job-#{job_a.id}")
    refute has_element?(view, "#runner-mac-a-job-#{job_b.id}")
    assert has_element?(view, "#runner-mac-b-job-#{job_b.id}")
    refute has_element?(view, "#runner-mac-b-job-#{job_a.id}")
  end

  test "a disconnected executor renders GONE, visibly distinct from a fresh idle one",
       %{conn: conn, board: board, stage: stage} do
    now = DateTime.utc_now()
    executor(board, "mac-live")

    executor(board, "mac-dead", last_heartbeat: DateTime.truncate(DateTime.add(now, -600, :second), :second))

    active_job(stage, "mac-dead")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    assert has_element?(view, "#runner-mac-live .badge-success", "FRESH")
    assert has_element?(view, "#runner-mac-dead .badge-error", "GONE")
    assert has_element?(view, "#runner-mac-dead", "ORPHANED JOB")
    assert has_element?(view, "#runner-mac-dead-at-risk")
    assert render(element(view, "#runner-mac-dead-at-risk")) =~ "exclusive runs park"
    assert has_element?(view, "#summary-fresh", "1 online")
    assert has_element?(view, "#summary-gone", "1 gone")
    # artboard: a gone executor's chips drop to the gray, dimmed treatment
    assert render(element(view, "#runner-mac-dead-pool-shared_clean")) =~ "opacity:0.7"
  end

  test "an executor that goes silent flips to STALE on the tick, with no reload",
       %{conn: conn, board: board, stage: stage} do
    executor(board, "mac-mini")
    active_job(stage, "mac-mini")
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")
    assert has_element?(view, "#runner-mac-mini .badge-success", "FRESH")

    Relay.Repo.update_all(Schemas.Executor,
      set: [last_heartbeat: DateTime.truncate(DateTime.add(DateTime.utc_now(), -50, :second), :second)]
    )

    send(view.pid, :tick)

    assert has_element?(view, "#runner-mac-mini .badge-warning", "STALE")
    assert has_element?(view, "#runner-mac-mini", "AT-RISK JOB")
  end

  test "the roster survives a cold Runs.Capacity — the page is a pure function of the DB",
       %{conn: conn, board: board, stage: stage} do
    executor = executor(board, "mac-mini", capacity: %{"shared_clean" => 2})
    active_job(stage, "mac-mini")

    # Simulates a fresh app boot: the ETS capacity store knows nothing about this executor
    # while its row and claimed job are still in Postgres. This is the restart case the card
    # is about. (Assert on this executor's key, not on an empty table — Runs.Capacity is a
    # single global ETS table shared with every other async test.)
    refute Map.has_key?(Relay.Runs.Capacity.snapshot(), executor.id)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    assert has_element?(view, "#runner-mac-mini")
    assert has_element?(view, "#runner-mac-mini-pool-shared_clean", "1/2")
    refute has_element?(view, "#runners-empty")
  end

  test "agent log lines land only under the executor holding that ref",
       %{conn: conn, board: board, stage: stage} do
    executor(board, "mac-a")
    executor(board, "mac-b")
    %{card: card} = active_job(stage, "mac-a")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    AgentLog.record(board.id, [%{"ref" => ref(board, card), "kind" => "claude", "text" => "hello a"}])

    assert has_element?(view, "#runner-mac-a-log", "hello a")
    refute has_element?(view, "#runner-mac-b-log", "hello a")
    # the artboard's dark terminal treatment (line ~118) — always-dark regardless of theme
    assert render(element(view, "#runner-mac-a-log")) =~ "background:var(--color-neutral)"
  end

  test "unclaimed-ref and ref-less lines render nowhere on this page",
       %{conn: conn, board: board, stage: stage} do
    executor(board, "mac-a")
    active_job(stage, "mac-a")
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    AgentLog.record(board.id, [
      %{"ref" => "MY9999", "kind" => "claude", "text" => "orphan line"},
      %{"kind" => "lifecycle", "text" => "board-level line"}
    ])

    html = render(view)
    refute html =~ "orphan line"
    refute html =~ "board-level line"
  end

  test "a host with dots gets a CSS-safe dom id", %{conn: conn, board: board} do
    executor(board, "mac.mini.local")
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    assert has_element?(view, "#runner-mac-mini-local", "mac.mini.local")
  end

  test "an outdated runner shows the OUTDATED pill instead of FRESH", %{conn: conn, board: board} do
    executor(board, "ancient", version: nil)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    assert has_element?(view, "#runner-ancient .badge-error", "OUTDATED")
    refute has_element?(view, "#runner-ancient .badge-success")
    refute has_element?(view, "#runner-ancient-outdated")
  end

  test "the OUTDATED pill uses badge-error", %{conn: conn, board: board} do
    executor(board, "ancient", version: nil)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    assert render(element(view, "#runner-ancient .badge-error")) =~ "OUTDATED"
  end

  test "a current runner shows no OUTDATED badge and a plain version line",
       %{conn: conn, board: board} do
    executor(board, "mac-mini", version: Relay.Runs.min_executor_version())

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    refute has_element?(view, "#runner-mac-mini-outdated")
    assert has_element?(view, "#runner-mac-mini-version", "v#{Relay.Runs.min_executor_version()}")
  end

  test "an outdated runner's version line names both versions", %{conn: conn, board: board} do
    executor(board, "old-box", version: 0)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    label = render(element(view, "#runner-old-box-version"))
    assert label =~ "v0"
    assert label =~ "requires v#{Relay.Runs.min_executor_version()}"
  end

  test "a runner that reports no version says so rather than showing a bare v", %{conn: conn, board: board} do
    executor(board, "ancient", version: nil)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    assert has_element?(view, "#runner-ancient-version", "unversioned")
  end

  test "an executor silent for over a day drops off the roster", %{conn: conn, board: board} do
    executor(board, "ancient", last_heartbeat: DateTime.truncate(DateTime.add(DateTime.utc_now(), -25, :hour), :second))

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    refute has_element?(view, "#runner-ancient")
    assert has_element?(view, "#runners-empty")
  end

  test "with no executors the empty state names the real start command",
       %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

    assert has_element?(view, "#runners-empty", "No runners connected")
    assert has_element?(view, "#runner-start-command", "bin/relay execute")
    assert has_element?(view, "#copy-start-command")
    assert has_element?(view, "#runners-empty", "Waiting for a heartbeat…")
    # deliberate deviation from the artboard: the real command, not npx relay-runner
    refute render(view) =~ "npx relay-runner"
    # RLY-139: the legacy watcher this empty state used to point at is deleted
    refute render(view) =~ "bin/relay watch"
  end

  test "board settings gains an ENGINE rail group linking to runners",
       %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

    assert has_element?(view, "#settings-rail", "ENGINE")
    assert has_element?(view, ~s|#settings-nav-runners[href="/board/#{board.slug}/runners"]|, "Runners")
    assert has_element?(view, "#settings-tab-runners")
  end

  describe "an outdated-but-beating executor (RLY-191)" do
    test "renders the OUTDATED pill, a non-pulsing rose dot, no FRESH pill, and the version line",
         %{conn: conn, board: board} do
      insert(:executor, board: board, name: "old", version: 0, last_heartbeat: DateTime.utc_now())

      {:ok, view, html} = live(conn, ~p"/board/#{board.slug}/runners")

      # the freshness pill IS the state now — OUTDATED, not FRESH
      assert html =~ "OUTDATED"
      refute has_element?(view, "#runner-old .badge-success")
      # non-pulsing dot: the header dot for this row must not carry animate-pulse
      refute has_element?(view, "#runner-old .animate-pulse")
      # the actionable version line survives
      assert has_element?(view, "#runner-old-version", "requires v#{Relay.Runs.min_executor_version()}")
      # header summary gains an N outdated chip
      assert has_element?(view, "#summary-outdated")
    end
  end

  describe "the QUEUE section (RE307)" do
    test "a job nobody has claimed renders with a QUEUED pill and a NODE tag",
         %{conn: conn, board: board, stage: stage} do
      %{card: card, job: job} = queued_job(stage, node_key: "write_plan")

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

      assert has_element?(view, "#queue-job-#{job.id}", ref(board, card))
      assert has_element?(view, "#queue-job-#{job.id}", "write_plan")
      assert has_element?(view, "#queue-job-#{job.id} .badge-ghost", "QUEUED")
      assert has_element?(view, "#queue-job-#{job.id}", "NODE")
      assert has_element?(view, "#queue-job-#{job.id}", "shared_clean")
      assert has_element?(view, "#queue-label", "QUEUE · 1")

      assert has_element?(
               view,
               ~s|#queue-job-#{job.id} a[href="/board/#{board.slug}?card=#{ref(board, card)}"]|
             )
    end

    test "the queue renders alongside the no-runners empty state, not instead of it",
         %{conn: conn, board: board, stage: stage} do
      %{job: job} = queued_job(stage)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

      # Both on screen at once — this is the case the page used to handle worst.
      assert has_element?(view, "#runners-empty", "No runners connected")
      assert has_element?(view, "#queue-job-#{job.id}")
      # ...and the empty state no longer reserves 62vh, which would push the queue off-screen.
      refute render(element(view, "#runners-empty")) =~ "62vh"
    end

    test "a claimed job names the runner holding it, in violet",
         %{conn: conn, board: board, stage: stage} do
      executor(board, "mac-mini")
      %{job: job} = active_job(stage, "mac-mini")

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

      row = render(element(view, "#queue-job-#{job.id}"))
      assert row =~ "CLAIMED"
      assert row =~ "badge-secondary"
      assert row =~ "mac-mini"
    end

    test "a queued talk turn is tagged TALK with no flow key and a dash isolation",
         %{conn: conn, board: board, stage: stage} do
      card = insert(:card, stage: stage, title: "Talk to me")
      job = Relay.Runs.insert_talk_job!(card, %{"turn_id" => 1}, nil)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

      row = render(element(view, "#queue-job-#{job.id}"))
      assert row =~ "TALK"
      # no isolation class → the dash placeholder, and no flow-key chip at all
      assert row =~ "—"
      refute has_element?(view, "#queue-job-#{job.id}-flow")
    end

    test "an idle board says nothing is queued", %{conn: conn, board: board} do
      executor(board, "mac-mini")

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

      assert has_element?(view, "#queue-empty", "Nothing queued or running.")
      assert has_element?(view, "#queue-label", "QUEUE · 0")
    end

    test "the stopped-work verdict renders above the rows when work has stopped",
         %{conn: conn, board: board, stage: stage} do
      # Queued 10 minutes with an empty roster: `stopped_work/1` returns :no_executor.
      queued_job(stage, age_s: 600)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

      assert has_element?(view, "#queue-diagnosis", "no executor is connected to run this board's work")
    end

    test "no diagnosis line on a board whose queue is merely young",
         %{conn: conn, board: board, stage: stage} do
      queued_job(stage, age_s: 5)
      executor(board, "mac-mini", version: Relay.Runs.min_executor_version())

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/runners")

      refute has_element?(view, "#queue-diagnosis")
    end
  end
end
