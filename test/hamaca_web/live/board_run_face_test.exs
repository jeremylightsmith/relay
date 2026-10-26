defmodule HamacaWeb.BoardRunFaceTest do
  use HamacaWeb.ConnCase, async: true

  import Ecto.Query
  import Hamaca.FanOutFixtures, only: [region_flow: 2, seed_region_run: 2]
  import Phoenix.LiveViewTest

  alias Hamaca.Boards
  alias Hamaca.Cards
  alias Hamaca.Flows
  alias Hamaca.Runs

  setup :register_and_log_in_user

  setup do
    start_capacity!()
    :ok
  end

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    %{board: board, code: code}
  end

  defp ai_card(stage, title, status) do
    {:ok, card} = Cards.create_card(stage, %{title: title})
    {:ok, card} = Cards.assign_ai(card)
    {:ok, card} = Cards.set_status(card, %{status: status})
    card
  end

  test "an active run's face replaces the legacy strip and updates on run_changed",
       %{conn: conn, board: board, code: code} do
    card = ai_card(code, "Mid flight", :working)
    run = insert(:run, card: card, current_node: "implement")
    insert(:node_execution, run: run, node: "branch")
    ref = Cards.ref(board, card)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    render_async(view)

    assert has_element?(view, "#card-#{ref}-run-face")
    assert has_element?(view, "[data-ref='#{ref}'].border-l-secondary")
    refute has_element?(view, "#card-#{ref}-log-strip")

    run |> Ecto.Changeset.change(status: :failed, current_node: "quality_review") |> Hamaca.Repo.update!()

    board_id = board.id
    attach_run_flush_telemetry()
    Runs.broadcast_run_changed(board.id, card.id)
    assert_receive {:run_flush, %{card_count: 1}, %{board_id: ^board_id}}, 500

    assert has_element?(view, "#card-#{ref}-run-face", "RUN FAILED")
    assert has_element?(view, "[data-ref='#{ref}'].border-l-error")
  end

  test "a failed run's tile names the node it died on after close_run!/3",
       %{conn: conn, board: board, code: code} do
    card = ai_card(code, "Died mid flight", :working)
    run = insert(:run, card: card, current_node: "quality_review")
    insert(:node_execution, run: run, node: "implement")
    insert(:node_execution, run: run, node: "quality_review", outcome: :failed)
    ref = Cards.ref(board, card)

    closed = Runs.close_run!(run, :failed, "boom")
    assert is_nil(closed.current_node)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    render_async(view)

    assert has_element?(view, "#card-#{ref}-run-face", "RUN FAILED")
    assert has_element?(view, "#card-#{ref}-run-face", "stuck at quality_review")
  end

  test "a cancelled run's tile names the node it stopped at",
       %{conn: conn, board: board, code: code} do
    card = ai_card(code, "Cancelled mid flight", :working)
    run = insert(:run, card: card, current_node: "implement")
    insert(:node_execution, run: run, node: "branch")
    insert(:node_execution, run: run, node: "implement", outcome: nil, duration_s: nil)
    ref = Cards.ref(board, card)

    closed = Runs.close_run!(run, :cancelled, nil)
    assert is_nil(closed.current_node)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    render_async(view)

    assert has_element?(view, "#card-#{ref}-run-face", "CANCELLED")
    assert has_element?(view, "#card-#{ref}-run-face", "stopped at implement")
  end

  test "a queued card face names the flow", %{conn: conn, board: board} do
    flow = Flows.get_flow!(board, "code")
    {:ok, flow} = Flows.enable_flow(flow)
    stage = Flows.neighbours(flow).pulls_from
    {:ok, card} = Cards.create_card(stage, %{title: "Waiting"})
    {:ok, card} = Cards.assign_ai(card)
    ref = Cards.ref(board, card)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    render_async(view)

    assert has_element?(view, "#card-#{ref}-run-face", "QUEUED · CODE FLOW")
  end

  test "a card that moved on after a terminal run falls back to legacy rendering",
       %{conn: conn, board: board} do
    flow = Flows.get_flow!(board, "code")
    backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
    %{pulls_from: pulls_from, lands_on: lands_on} = Flows.neighbours(flow)
    true = backlog.id not in [pulls_from.id, flow.stage_id, lands_on.id]
    {:ok, card} = Cards.create_card(backlog, %{title: "Moved on"})
    insert(:run, card: card, status: :done, current_node: nil, finished_at: DateTime.utc_now())
    ref = Cards.ref(board, card)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    render_async(view)

    refute has_element?(view, "#card-#{ref}-run-face")
  end

  describe "an open fan-out region (RE440)" do
    setup %{board: board, code: code} do
      region_flow(board, insert(:stage, board: board, type: :work, category: :in_progress, position: 100))
      card = ai_card(code, "Fanned out", :working)
      {_run, branches} = seed_region_run(card, [{"a", :ended, :succeeded}, {"b1", :running, nil}, {"c", :queued, nil}])

      %{card: card, ref: Cards.ref(board, card), branches: branches}
    end

    test "the face counts the branches and splits the fan_out's segment (scenario 9)",
         %{conn: conn, board: board, ref: ref} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      render_async(view)

      face = view |> element("#card-#{ref}-run-face") |> render() |> LazyHTML.from_fragment()

      assert face |> LazyHTML.query(".run-face-branches") |> LazyHTML.text() |> squish() ==
               "· 1/3 branches · 1 queued"

      assert face |> LazyHTML.query(".run-branch-segment .run-branch-bar") |> LazyHTML.attribute("class") == [
               "run-branch-bar run-branch-bar-succeeded",
               "run-branch-bar run-branch-bar-running",
               "run-branch-bar run-branch-bar-queued"
             ]
    end

    test "the branch count leaves the face once every branch has ended (scenario 10)",
         %{conn: conn, board: board, card: card, ref: ref, branches: branches} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      render_async(view)
      assert has_element?(view, "#card-#{ref}-run-face .run-face-branches")

      for branch <- branches, do: branch |> Ecto.Changeset.change(state: :ended) |> Hamaca.Repo.update!()

      board_id = board.id
      attach_run_flush_telemetry()
      Runs.broadcast_run_changed(board.id, card.id)
      assert_receive {:run_flush, %{card_count: 1}, %{board_id: ^board_id}}, 500

      refute has_element?(view, "#card-#{ref}-run-face .run-face-branches")
    end
  end

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  # RLY-191: the run face ages visibly and escalates to the amber stalled treatment. A
  # fresh board (rather than the default board reused above) — explicit stage positions
  # avoid colliding with the default board's own 1..11 sequence on `stages_board_id_position_index`.
  describe "age and stall (RLY-191)" do
    setup %{user: user} do
      board = insert(:board, owner: user)
      insert(:membership, board: board, user: user)
      works = insert_ai_stage(%{board: board, name: "Code", position: 1})
      %{board: board, works: works}
    end

    defp face_ref(board, card), do: "#{board.key}#{card.ref_number}"

    test "a running run face shows an age", %{conn: conn, board: board, works: works} do
      card = insert(:card, stage: works, status: :working)
      run = insert(:run, card: card, status: :running, current_node: "implement")
      insert(:node_execution, run: run, node_key: "implement", outcome: nil, finished_at: nil)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#card-#{face_ref(board, card)}-run-face")
      assert has_element?(view, "#card-#{face_ref(board, card)}-run-age")
    end

    test "a run whose job is queued past the threshold gets the stalled treatment",
         %{conn: conn, board: board, works: works} do
      now = DateTime.truncate(DateTime.utc_now(), :second)
      card = insert(:card, stage: works, status: :working)
      run = insert(:run, card: card, status: :running, current_node: "implement")

      exec =
        insert(:node_execution,
          run: run,
          node_key: "implement",
          outcome: nil,
          finished_at: nil,
          inserted_at: DateTime.add(now, -900, :second)
        )

      insert(:node_job, node_execution: exec, state: :queued, runner_name: nil, claimed_at: nil)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, ~s(#card-#{face_ref(board, card)}-run-face[data-stalled="true"]))
    end

    test "a claimed job on a live runner stays neutral and keeps its age readout",
         %{conn: conn, board: board, works: works} do
      now = DateTime.truncate(DateTime.utc_now(), :second)
      old = DateTime.add(now, -600, :second)
      insert(:runner, board: board, name: "live", last_heartbeat: now)
      card = insert(:card, stage: works, status: :working)
      run = insert(:run, card: card, status: :running, current_node: "implement")

      exec =
        insert(:node_execution,
          run: run,
          node_key: "implement",
          outcome: nil,
          finished_at: nil,
          inserted_at: old
        )

      insert(:node_job, node_execution: exec, state: :claimed, runner_name: "live", claimed_at: old)

      ref = face_ref(board, card)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, ~s(#card-#{ref}-run-face[data-stalled="false"]))
      refute has_element?(view, "#card-#{ref}-run-face .run-face-stalled-note")
      # Decision 3: the elapsed-time readout is preserved, not coupled to @stalled?.
      assert has_element?(view, "#card-#{ref}-run-age")
    end
  end

  describe "rate limited (RE320)" do
    setup %{user: user} do
      board = insert(:board, owner: user)
      insert(:membership, board: board, user: user)
      works = insert_ai_stage(%{board: board, name: "Code", position: 1})
      %{board: board, works: works, now: DateTime.truncate(DateTime.utc_now(), :second)}
    end

    # A live run whose current node-job has sat queued `age_s` seconds.
    defp queued_run_card(works, now, age_s) do
      at = DateTime.add(now, -age_s, :second)
      card = insert(:card, stage: works, status: :working)
      run = insert(:run, card: card, status: :running, current_node: "implement")
      exec = insert(:node_execution, run: run, node_key: "implement", outcome: nil, finished_at: nil, inserted_at: at)
      insert(:node_job, node_execution: exec, state: :queued, runner_name: nil, claimed_at: nil, inserted_at: at)
      card
    end

    test "a queued job behind the only, paused runner shows the chip instead of stalled",
         %{conn: conn, board: board, works: works, now: now} do
      resets_at = DateTime.add(now, 3600, :second)

      insert(:runner,
        board: board,
        name: "paused",
        last_heartbeat: now,
        harnesses: [runner_harness("claude-code", usage: paused_usage(resets_at))]
      )

      card = queued_run_card(works, now, 900)
      ref = face_ref(board, card)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, ~s(#card-#{ref}-run-face[data-rate-limited="true"]))
      assert has_element?(view, ~s(#card-#{ref}-run-face[data-stalled="false"]))

      assert has_element?(
               view,
               "#card-#{ref}-rate-limited",
               "Rate limited · resumes #{Runs.resume_time_label(resets_at)}"
             )

      assert has_element?(view, "#stopped-work-banner", "paused at its usage limits")
    end

    test "the drawer's Run tab carries the rate-limited diagnosis",
         %{conn: conn, board: board, works: works, now: now} do
      resets_at = DateTime.add(now, 3600, :second)

      insert(:runner,
        board: board,
        name: "paused",
        last_heartbeat: now,
        harnesses: [runner_harness("claude-code", usage: paused_usage(resets_at))]
      )

      card = queued_run_card(works, now, 900)
      ref = face_ref(board, card)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
      render_async(view)

      assert has_element?(
               view,
               "#card-drawer-tab-panel-run #run-banner-rate-limited",
               "every connected runner is paused at its usage limits. " <>
                 "Resumes #{Runs.resume_time_label(resets_at)}."
             )
    end

    test "the drawer's Activity chip says paused, not gone quiet, for a quiet rate-limited card",
         %{conn: conn, board: board, works: works, now: now} do
      resets_at = DateTime.add(now, 3600, :second)

      insert(:runner,
        board: board,
        name: "paused",
        last_heartbeat: now,
        harnesses: [runner_harness("claude-code", usage: paused_usage(resets_at))]
      )

      {:ok, card} = works |> queued_run_card(now, 900) |> Cards.assign_ai()
      quiet = DateTime.add(now, -900, :second)
      insert(:activity, card: card, type: :action, text: "claimed")

      Hamaca.Repo.update_all(from(a in Schemas.Activity, where: a.card_id == ^card.id), set: [inserted_at: quiet])
      ref = face_ref(board, card)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
      render_async(view)

      assert has_element?(view, "#card-drawer-activity-health-chip[data-health='stale']")

      assert has_element?(
               view,
               "#card-drawer-activity-health-chip",
               "Rate limited · resumes #{Runs.resume_time_label(resets_at)}"
             )

      refute has_element?(view, "#card-drawer-activity-health-chip", "gone quiet")
    end

    test "the drawer shows no rate-limited diagnosis when another runner is free",
         %{conn: conn, board: board, works: works, now: now} do
      insert(:runner,
        board: board,
        name: "paused",
        last_heartbeat: now,
        harnesses: [runner_harness("claude-code", usage: paused_usage(DateTime.add(now, 3600, :second)))]
      )

      insert(:runner, board: board, name: "free", last_heartbeat: now)
      card = queued_run_card(works, now, 900)
      ref = face_ref(board, card)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
      render_async(view)

      assert has_element?(view, "#card-drawer-tab-panel-run")
      refute has_element?(view, "#run-banner-rate-limited")
    end

    test "nothing is flagged when another connected runner is free",
         %{conn: conn, board: board, works: works, now: now} do
      insert(:runner,
        board: board,
        name: "paused",
        last_heartbeat: now,
        harnesses: [runner_harness("claude-code", usage: paused_usage(DateTime.add(now, 3600, :second)))]
      )

      insert(:runner, board: board, name: "free", last_heartbeat: now)
      card = queued_run_card(works, now, 900)
      ref = face_ref(board, card)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, ~s(#card-#{ref}-run-face[data-rate-limited="false"]))
      refute has_element?(view, "#card-#{ref}-rate-limited")
      refute has_element?(view, "#stopped-work-banner")
    end
  end

  # RLY-204: BoardLive coalesces run events behind a ~150ms debounce (mark_run_dirty/2 +
  # :flush_run_changes) rather than refetching on every broadcast — so a test that changes a
  # run and immediately asserts on the rendered face must first wait for that flush.
  defp attach_run_flush_telemetry do
    handler_id = "test-run-flush-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:hamaca, :board, :run_flush],
      fn _event, measurements, metadata, _config -> send(test_pid, {:run_flush, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end
end
