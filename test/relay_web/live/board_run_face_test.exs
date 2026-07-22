defmodule RelayWeb.BoardRunFaceTest do
  # RLY-191: the describe block below resets the global `Relay.Runs.Capacity` ETS table, so
  # this module can no longer run concurrently with other async tests touching capacity.
  use RelayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Flows
  alias Relay.Runs

  setup :register_and_log_in_user

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

    run |> Ecto.Changeset.change(status: :failed, current_node: "quality_review") |> Relay.Repo.update!()

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
    stage = Enum.find(board.stages, &(&1.id == flow.pulls_from_stage_id))
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
    true = backlog.id not in [flow.pulls_from_stage_id, flow.works_in_stage_id, flow.lands_on_stage_id]
    {:ok, card} = Cards.create_card(backlog, %{title: "Moved on"})
    insert(:run, card: card, status: :done, current_node: nil, finished_at: DateTime.utc_now())
    ref = Cards.ref(board, card)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    render_async(view)

    refute has_element?(view, "#card-#{ref}-run-face")
  end

  # RLY-191: the run face ages visibly and escalates to the amber stalled treatment. A
  # fresh board (rather than the default board reused above) — explicit stage positions
  # avoid colliding with the default board's own 1..11 sequence on `stages_board_id_position_index`.
  describe "age and stall (RLY-191)" do
    setup %{user: user} do
      Relay.Runs.Capacity.reset()
      board = insert(:board, owner: user)
      insert(:membership, board: board, user: user)
      works = insert(:stage, board: board, name: "Code", position: 1, type: :work, ai_enabled: true)
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

      insert(:node_job, node_execution: exec, state: :queued, executor_name: nil, claimed_at: nil)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, ~s(#card-#{face_ref(board, card)}-run-face[data-stalled="true"]))
    end

    test "a claimed, running job stays neutral however old it is (the long-node case)",
         %{conn: conn, board: board, works: works} do
      now = DateTime.truncate(DateTime.utc_now(), :second)
      insert(:executor, board: board, name: "live", last_heartbeat: now)
      card = insert(:card, stage: works, status: :working)
      run = insert(:run, card: card, status: :running, current_node: "implement")

      exec =
        insert(:node_execution,
          run: run,
          node_key: "implement",
          outcome: nil,
          finished_at: nil,
          inserted_at: DateTime.add(now, -3600, :second)
        )

      insert(:node_job,
        node_execution: exec,
        state: :running,
        executor_name: "live",
        claimed_at: DateTime.add(now, -3600, :second)
      )

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, ~s(#card-#{face_ref(board, card)}-run-face[data-stalled="false"]))
      assert has_element?(view, "#card-#{face_ref(board, card)}-run-age")
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
      [:relay, :board, :run_flush],
      fn _event, measurements, metadata, _config -> send(test_pid, {:run_flush, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end
end
