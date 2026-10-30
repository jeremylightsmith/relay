defmodule Hamaca.TalkTest do
  @moduledoc """
  RE268 — the transcript store's promises (ADR 0014): `seq` strictly increasing with
  no gaps, a replayed batch stores and broadcasts nothing new, `clear/1` hides without
  deleting, Stop revokes, and posting a turn creates a claimable talk job.
  """
  use Hamaca.DataCase, async: true

  alias Hamaca.Repo
  alias Hamaca.Runs
  alias Hamaca.Talk
  alias Schemas.TalkEvent
  alias Schemas.TalkTurn

  setup do
    board = insert(:board)
    stage = insert(:stage, board: board)

    card =
      insert(:card,
        board: board,
        stage: stage,
        description: "Export buffers the whole result set.",
        acceptance_criteria: "1. It streams.",
        plan: "## Task 1: A\n\n## Task 2: B\n"
      )

    for title <- ~w(A B), do: insert(:sub_task, card: card, title: title)

    author = insert(:user)

    runner =
      insert(:runner,
        board: board,
        name: "mac-1",
        capacity: %{"shared_clean" => 1, "exclusive" => 1},
        version: Runs.shared_talk_min_version()
      )

    %{board: board, stage: stage, card: card, author: author, runner: runner}
  end

  test "the closed sets are defined once" do
    assert TalkTurn.statuses() == [:queued, :claimed, :done, :stopped, :failed]
    assert TalkTurn.active_statuses() == [:queued, :claimed]
    assert TalkEvent.kinds() == [:user, :tool, :out, :error]
  end

  test "a session is created once per card and recomputes its seed", ctx do
    session = Talk.session_for_card(ctx.card)
    again = Talk.session_for_card(ctx.card)

    assert session.id == again.id
    assert session.seed_summary =~ "3 fields"
    assert session.seed_summary =~ "plan 2 steps"
    assert Enum.any?(session.seed_fields, &(&1["label"] == "description"))
    assert Enum.any?(session.seed_fields, &(&1["label"] == "plan"))
  end

  test "a plan's `## Task` headings are not steps — a card with no tasks has no plan yet (RE487)", ctx do
    card = insert(:card, board: ctx.board, stage: ctx.stage, plan: "## Task 1: A\n\n## Task 2: B\n")

    assert Talk.session_for_card(card).seed_summary =~ "no plan yet"
  end

  test "a header-only plan counts the card's tasks, not its headings (RE357)", ctx do
    card =
      insert(:card,
        board: ctx.board,
        stage: ctx.stage,
        plan: "# Goal\n\nShip it.\n\n## Verification\n- Gate: `mix precommit`\n"
      )

    for title <- ~w(A B C), do: insert(:sub_task, card: card, title: title)

    assert Talk.session_for_card(card).seed_summary =~ "plan 3 steps"
  end

  # RE268 whole-branch review — the drawer hands `session_for_card/1` the LIGHT card
  # (`Cards.get_card_light_by_ref/2`) until its async body fill lands, and the light projection
  # nils exactly the four heavy fields `build_seed/1` reads. Pressing `t` in that window used to
  # persist a `0 fields · no plan yet` seed and send a context-free seed to the model.
  test "the seed is built from the stored card even when handed a partially-selected struct", ctx do
    light = %{ctx.card | description: nil, acceptance_criteria: nil, spec: nil, plan: nil}

    session = Talk.session_for_card(light)

    assert session.seed_summary =~ "3 fields"
    assert session.seed_summary =~ "plan 2 steps"
    assert Enum.any?(session.seed_fields, &(&1["label"] == "description"))
  end

  test "posting a message writes the user line, a queued turn and a claimable talk job", ctx do
    Talk.subscribe(ctx.card.id)

    assert {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "why is this stuck?")
    assert turn.status == :queued
    assert turn.prompt == "why is this stuck?"

    assert_receive {:talk_event, %TalkEvent{kind: :user, text: "why is this stuck?", seq: 1}}
    assert_receive {:talk_turn_changed, %TalkTurn{status: :queued}}

    job = Runs.get_job(turn.node_job_id)
    assert job.kind == :talk
    assert job.payload["turn_id"] == turn.id
    assert job.payload["prompt"] == "why is this stuck?"
    assert job.payload["seed"]["summary"] =~ "3 fields"
    assert is_nil(job.payload["resume_session"])

    assert {:ok, claimed} = Runs.claim_next_job(ctx.runner)
    assert claimed.id == job.id
  end

  # RE268 whole-branch review — `:claimed` was a documented-but-unreachable status: a turn stayed
  # `:queued` for its whole life, including while `claude -p` ran, falsifying five doc lines.
  test "claiming a turn's job moves the turn to :claimed and broadcasts it", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "why is this stuck?")
    Talk.subscribe(ctx.card.id)

    {:ok, job} = Runs.claim_next_job(ctx.runner)
    assert {:ok, claimed} = Talk.mark_claimed(job)

    assert claimed.status == :claimed
    assert Talk.get_turn(turn.id).status == :claimed
    assert Talk.active_turn(Talk.session_for_card(ctx.card)).id == turn.id
    assert_receive {:talk_turn_changed, %TalkTurn{status: :claimed}}
  end

  test "a turn already ended by Stop is not dragged back to :claimed", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "why is this stuck?")
    {:ok, _stopped} = Talk.stop_turn(turn)

    job = Runs.get_job(turn.node_job_id)

    assert {:error, :not_queued} = Talk.mark_claimed(job)
    assert Talk.get_turn(turn.id).status == :stopped
  end

  test "a blank message is refused and a second turn is refused while one is in flight", ctx do
    assert {:error, :blank} = Talk.post_message(ctx.card, ctx.author, "   ")
    assert {:ok, _turn} = Talk.post_message(ctx.card, ctx.author, "first")
    assert {:error, :turn_in_flight} = Talk.post_message(ctx.card, ctx.author, "second")
  end

  test "seq is strictly increasing across turns and never a timestamp", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
    {:ok, _} = Talk.append_events(turn, [event(1, "tool", "Read · lib/hamaca.ex"), event(2, "out", "answer")])
    {:ok, _} = Talk.finish_turn(turn, :done, %{session_id: "sess-1"})
    {:ok, two} = Talk.post_message(ctx.card, ctx.author, "two")
    {:ok, _} = Talk.append_events(two, [event(1, "out", "second answer")])

    session = Talk.session_for_card(ctx.card)
    seqs = session |> Talk.events() |> Enum.map(& &1.seq)

    assert seqs == Enum.to_list(1..length(seqs))
    assert Talk.session_for_card(ctx.card).last_event_seq == List.last(seqs)
  end

  test "a replayed batch inserts no duplicate rows, skips none, and broadcasts nothing new", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
    batch = [event(1, "out", "a"), event(2, "out", "b")]

    {:ok, first} = Talk.append_events(turn, batch)
    Talk.subscribe(ctx.card.id)
    {:ok, replayed} = Talk.append_events(turn, batch)

    assert length(first) == 2
    assert replayed == []
    refute_receive {:talk_event, _}, 50

    session = Talk.session_for_card(ctx.card)
    assert session |> Talk.events() |> length() == 3
  end

  test "a partly-replayed batch stores only the new lines", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
    {:ok, _} = Talk.append_events(turn, [event(1, "out", "a")])
    {:ok, stored} = Talk.append_events(turn, [event(1, "out", "a"), event(2, "out", "b")])

    assert Enum.map(stored, & &1.client_seq) == [2]
  end

  test "finishing a turn persists the claude session id and pins the runner", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
    {:ok, _claimed} = Runs.claim_next_job(ctx.runner)

    {:ok, done} = Talk.finish_turn(turn, :done, %{session_id: "sess-abc"})
    assert done.status == :done

    session = Talk.session_for_card(ctx.card)
    assert session.claude_session_id == "sess-abc"
    assert session.pinned_runner_name == "mac-1"
    assert Runs.get_job(turn.node_job_id).state == :done
  end

  test "the next turn resumes the stored session and is pinned to its holder", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
    {:ok, _} = Runs.claim_next_job(ctx.runner)
    {:ok, _} = Talk.finish_turn(turn, :done, %{session_id: "sess-abc"})

    {:ok, two} = Talk.post_message(ctx.card, ctx.author, "two")
    job = Runs.get_job(two.node_job_id)

    assert job.payload["resume_session"] == "sess-abc"
    assert job.runner_name == "mac-1"
  end

  test "stop revokes the job, ends the turn non-error, and keeps the partial output", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
    {:ok, _} = Runs.claim_next_job(ctx.runner)
    {:ok, _} = Talk.append_events(turn, [event(1, "out", "half an ans")])

    Talk.subscribe(ctx.card.id)
    assert {:ok, stopped} = Talk.stop_turn(turn)

    assert stopped.status == :stopped
    assert Runs.get_job(turn.node_job_id).state == :revoked
    assert_receive {:talk_turn_changed, %TalkTurn{status: :stopped}}

    texts = ctx.card |> Talk.session_for_card() |> Talk.events() |> Enum.map(& &1.text)
    assert "half an ans" in texts

    assert {:error, :not_active} = Talk.stop_turn(Talk.get_turn(turn.id))
  end

  test "clear hides the scrollback without deleting a row", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
    {:ok, _} = Talk.append_events(turn, [event(1, "out", "a")])
    {:ok, _} = Talk.finish_turn(turn, :done, %{session_id: "s"})

    session = Talk.session_for_card(ctx.card)
    {:ok, cleared} = Talk.clear(session)

    assert Talk.events(cleared) == []
    assert cleared.cleared_through_seq == session.last_event_seq
    assert Repo.aggregate(TalkEvent, :count) == 2
  end

  test "a talk turn is claimable while a node job is live on the same card", ctx do
    run = insert(:run, card: ctx.card)
    execution = insert(:node_execution, run: run)
    node_job = Runs.insert_job!(run, execution, %{"isolation" => "exclusive"})

    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "what is happening?")

    assert {:ok, first} = Runs.claim_next_job(ctx.runner)
    assert first.id == node_job.id
    assert {:ok, second} = Runs.claim_next_job(ctx.runner)
    assert second.id == turn.node_job_id
  end

  test "events/2 with :limit returns the highest seqs, in ascending order", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
    {:ok, _} = Talk.append_events(turn, [event(1, "out", "a"), event(2, "out", "b"), event(3, "out", "c")])

    session = Talk.session_for_card(ctx.card)
    seqs = session |> Talk.events(limit: 2) |> Enum.map(& &1.seq)

    assert seqs == [3, 4]
  end

  test "only one turn wins when posts race on the same session", ctx do
    results =
      1..5
      |> Task.async_stream(fn i -> Talk.post_message(ctx.card, ctx.author, "msg #{i}") end,
        max_concurrency: 5,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :turn_in_flight})) == 4
  end

  test "finish_turn as :stopped or :failed leaves the claude session id and pin untouched", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
    {:ok, _claimed} = Runs.claim_next_job(ctx.runner)

    {:ok, stopped} = Talk.finish_turn(turn, :stopped)
    assert stopped.status == :stopped

    session = Talk.session_for_card(ctx.card)
    assert session.claude_session_id == nil
    assert session.pinned_runner_name == nil
  end

  test "an unknown event kind degrades to :out", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
    {:ok, [stored]} = Talk.append_events(turn, [event(1, "mystery", "huh")])

    assert stored.kind == :out
  end

  test "a line missing client_seq is dropped without failing the batch", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
    bad = %{"kind" => "out", "text" => "no client_seq", "dim" => false}

    assert {:ok, stored} = Talk.append_events(turn, [bad, event(1, "out", "good")])
    assert Enum.map(stored, & &1.text) == ["good"]
  end

  test "a non-map element is dropped without failing the batch", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")

    assert {:ok, stored} = Talk.append_events(turn, ["oops", event(1, "out", "good")])
    assert Enum.map(stored, & &1.text) == ["good"]
  end

  test "a line with no text, blank text, or a non-string text is dropped without failing the batch", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")

    missing = %{"client_seq" => 7, "kind" => "out", "dim" => false}
    blank = %{"client_seq" => 8, "kind" => "out", "text" => "   ", "dim" => false}
    object = %{"client_seq" => 9, "kind" => "out", "text" => %{"a" => 1}, "dim" => false}

    assert {:ok, stored} = Talk.append_events(turn, [missing, blank, object, event(1, "out", "good")])
    assert Enum.map(stored, & &1.text) == ["good"]
  end

  test "a client_seq outside int4 is dropped instead of 500ing the whole batch", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")

    # Passes is_integer/1 and the Ecto cast, then raises Postgrex 22003 from Repo.insert! —
    # rolling the transaction back and losing every valid line with it.
    too_big = %{"client_seq" => 99_999_999_999_999, "kind" => "out", "text" => "boom", "dim" => false}
    negative = %{"client_seq" => -1, "kind" => "out", "text" => "nope", "dim" => false}

    assert {:ok, stored} = Talk.append_events(turn, [too_big, negative, event(1, "out", "good")])
    assert Enum.map(stored, & &1.text) == ["good"]
  end

  test "a line whose kind is not a string is dropped without failing the batch", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
    bad = %{"client_seq" => 4, "kind" => %{"nope" => true}, "text" => "hi", "dim" => false}

    assert {:ok, stored} = Talk.append_events(turn, [bad, event(1, "out", "good")])
    assert Enum.map(stored, & &1.text) == ["good"]
  end

  test "the seed line counts in the singular when there is one of something", ctx do
    bare = insert(:card, board: ctx.board, stage: ctx.stage, description: "just the one field")

    seed = Talk.build_seed(bare)

    # The seed line is the first thing a person reads in the pane; "1 fields" is a small lie in
    # a prominent place.
    assert seed.summary =~ "1 field ·"
    refute seed.summary =~ "1 fields"
    assert seed.summary =~ "0 runs"
  end

  test "Stop wakes the claim long-poll, so the revocation does not wait for a heartbeat", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")

    # The claim long-poll subscribes to the board's run events; `post_message/3` already
    # broadcasts one so a NEW turn is picked up promptly. Without the same broadcast here, a Stop
    # is invisible to that open connection and only reaches the runner on the next 15s beat —
    # which is why pressing Stop left `claude` streaming for ~13s.
    :ok = Runs.subscribe(ctx.card.board_id)

    {:ok, _stopped} = Talk.stop_turn(turn)

    assert_receive run_event when elem(run_event, 0) == :run_changed
  end

  test "a turn ended by Stop is not resurrected as :done by a late outcome", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
    {:ok, stopped} = Talk.stop_turn(turn)

    assert {:ok, still} = Talk.finish_turn(stopped, :done, %{session_id: "sess-late"})
    assert still.status == :stopped
    assert Talk.session_for_card(ctx.card).claude_session_id == nil
    assert Talk.session_for_card(ctx.card).pinned_runner_name == nil
  end

  test "a replayed outcome POST does not rewrite the session or re-broadcast", ctx do
    {:ok, _queued} = Talk.post_message(ctx.card, ctx.author, "one")
    {:ok, job} = Runs.claim_next_job(ctx.runner)
    {:ok, turn} = Talk.mark_claimed(job)

    {:ok, done} = Talk.finish_turn(turn, :done, %{session_id: "sess-1"})
    Talk.subscribe(ctx.card.id)

    assert {:ok, again} = Talk.finish_turn(done, :failed, %{detail: "late"})
    assert again.status == :done
    refute_receive {:talk_turn_changed, _}, 50
    assert Talk.session_for_card(ctx.card).claude_session_id == "sess-1"
  end

  describe "post-time release of a gone pin (RE493)" do
    @notice ~s(Runner "ghost-runner" is gone — this message starts a fresh session on the next available runner. It won't remember earlier turns.)

    test "a pin naming a runner with no row goes out unpinned and fresh", ctx do
      pin_session!(ctx.card, "ghost-runner", "sess-old")

      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "hello")
      job = Runs.get_job(turn.node_job_id)

      assert job.runner_name == nil
      assert job.payload["resume_session"] == nil
      assert is_binary(job.payload["seed"]["summary"])

      session = Talk.get_session(ctx.card)
      assert session.pinned_runner_name == nil
      assert session.claude_session_id == nil
    end

    test "a pin naming a runner silent past the exclusive reclaim window is released", ctx do
      pin_session!(ctx.card, "mac-1", "sess-old")
      silence!(ctx.runner, Runs.exclusive_reclaim_after_s() + 5)

      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "hello")
      job = Runs.get_job(turn.node_job_id)

      assert job.runner_name == nil
      assert job.payload["resume_session"] == nil
      assert is_binary(job.payload["seed"]["summary"])

      session = Talk.get_session(ctx.card)
      assert session.pinned_runner_name == nil
      assert session.claude_session_id == nil
    end

    test "a released post writes the notice line right after the user line, and broadcasts both", ctx do
      pin_session!(ctx.card, "ghost-runner", "sess-old")
      Talk.subscribe(ctx.card.id)

      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "hello")

      [user, notice] = ctx.card |> Talk.get_session() |> Talk.events() |> Enum.filter(&(&1.talk_turn_id == turn.id))

      assert %TalkEvent{kind: :user, text: "hello", client_seq: 0} = user
      assert %TalkEvent{kind: :error, dim: false, client_seq: -1, text: @notice} = notice
      assert notice.seq == user.seq + 1

      user_id = user.id
      notice_id = notice.id
      assert_receive {:talk_event, %TalkEvent{id: ^user_id}}
      assert_receive {:talk_event, %TalkEvent{id: ^notice_id}}
    end

    test "a merely stale pin is kept, resumed, and gets no notice", ctx do
      pin_session!(ctx.card, "mac-1", "sess-abc")
      silence!(ctx.runner, 120)

      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "hello")
      job = Runs.get_job(turn.node_job_id)

      assert job.runner_name == "mac-1"
      assert job.payload["resume_session"] == "sess-abc"

      session = Talk.get_session(ctx.card)
      assert session.pinned_runner_name == "mac-1"
      assert session.claude_session_id == "sess-abc"
      assert error_events(turn) == []
    end

    test "a live pin is unchanged and gets no notice", ctx do
      {:ok, one} = Talk.post_message(ctx.card, ctx.author, "one")
      {:ok, _} = Runs.claim_next_job(ctx.runner)
      {:ok, _} = Talk.finish_turn(one, :done, %{session_id: "sess-abc"})

      {:ok, two} = Talk.post_message(ctx.card, ctx.author, "two")
      job = Runs.get_job(two.node_job_id)

      assert job.runner_name == "mac-1"
      assert job.payload["resume_session"] == "sess-abc"
      assert error_events(two) == []
    end

    test "a released turn re-pins to whichever runner claims and finishes it", ctx do
      pin_session!(ctx.card, "ghost-runner", "sess-old")
      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "hello")

      mac2 =
        insert(:runner,
          board: ctx.board,
          name: "mac-2",
          capacity: %{"shared_clean" => 1, "exclusive" => 1},
          version: Runs.shared_talk_min_version()
        )

      job_id = turn.node_job_id
      assert {:ok, %{id: ^job_id}} = Runs.claim_next_job(mac2)
      {:ok, _} = Talk.finish_turn(turn, :done, %{session_id: "sess-new"})

      session = Talk.get_session(ctx.card)
      assert session.pinned_runner_name == "mac-2"
      assert session.claude_session_id == "sess-new"

      {:ok, third} = Talk.post_message(ctx.card, ctx.author, "again")
      assert Runs.get_job(third.node_job_id).runner_name == "mac-2"
      assert error_events(third) == []
    end

    test "a session with no pin yet gets no notice", ctx do
      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "first")

      assert Talk.get_session(ctx.card).pinned_runner_name == nil
      assert error_events(turn) == []
    end
  end

  describe "talk isolation per turn (RE366)" do
    @to_shared "Started a fresh session — this turn reads a clean checkout of the base branch (read-only)."
    @to_exclusive "Started a fresh session — this turn runs in the card's own worktree."

    test "a turn on a card with no runs is posted shared_clean", ctx do
      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "hi")

      assert Runs.get_job(turn.node_job_id).payload["isolation"] == "shared_clean"
    end

    test "a turn on a card with an active exclusive run is posted exclusive", ctx do
      exclusive_run!(ctx)

      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "hi")

      assert Runs.get_job(turn.node_job_id).payload["isolation"] == "exclusive"
    end

    test "a switch from shared to exclusive starts fresh and says so", ctx do
      pin_session!(ctx.card, "mac-1", "s-1", :shared_clean)
      exclusive_run!(ctx)

      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "hello")
      job = Runs.get_job(turn.node_job_id)

      assert job.payload["isolation"] == "exclusive"
      assert job.payload["resume_session"] == nil

      assert [
               %TalkEvent{kind: :user, client_seq: 0, text: "hello"},
               %TalkEvent{kind: :out, dim: true, client_seq: -1, text: @to_exclusive}
             ] = turn_events(turn)
    end

    test "a switch from exclusive to shared starts fresh and says so", ctx do
      pin_session!(ctx.card, "mac-1", "s-1", :exclusive)

      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "hello")
      job = Runs.get_job(turn.node_job_id)

      assert job.payload["isolation"] == "shared_clean"
      assert job.payload["resume_session"] == nil

      assert [
               %TalkEvent{kind: :user, client_seq: 0},
               %TalkEvent{kind: :out, dim: true, client_seq: -1, text: @to_shared}
             ] = turn_events(turn)
    end

    test "a switch keeps the pin — the same machine still holds the session", ctx do
      pin_session!(ctx.card, "mac-1", "s-1", :exclusive)

      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "hello")

      assert Runs.get_job(turn.node_job_id).runner_name == "mac-1"
    end

    test "an unchanged isolation resumes the session with no notice", ctx do
      pin_session!(ctx.card, "mac-1", "s-1", :shared_clean)

      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "hello")

      assert Runs.get_job(turn.node_job_id).payload["resume_session"] == "s-1"
      assert [%TalkEvent{kind: :user, client_seq: 0}] = turn_events(turn)
    end

    test "a first turn never announces a switch, whatever the stored isolation", ctx do
      pin_session!(ctx.card, nil, nil, :exclusive)

      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "hello")

      assert Runs.get_job(turn.node_job_id).payload["resume_session"] == nil
      assert [%TalkEvent{kind: :user, client_seq: 0}] = turn_events(turn)
    end

    test "a gone pin and a switch on one turn share ONE error notice", ctx do
      pin_session!(ctx.card, "ghost-runner", "s-1", :exclusive)

      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "hello")
      job = Runs.get_job(turn.node_job_id)

      gone =
        ~s(Runner "ghost-runner" is gone — this message starts a fresh session on the next available runner. It won't remember earlier turns.)

      assert job.runner_name == nil
      assert job.payload["resume_session"] == nil

      assert [%TalkEvent{kind: :user}, notice] = turn_events(turn)
      assert %TalkEvent{kind: :error, dim: false, client_seq: -1} = notice
      assert notice.text == gone <> " " <> @to_shared
    end

    test "a finished turn records the isolation its session was created under", ctx do
      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
      {:ok, claimed} = Runs.claim_next_job(ctx.runner)
      assert claimed.payload["isolation"] == "shared_clean"

      {:ok, _} = Talk.finish_turn(turn, :done, %{session_id: "s-9"})

      session = Talk.get_session(ctx.card)
      assert session.claude_session_id == "s-9"
      assert session.claude_session_isolation == :shared_clean
    end

    test "a finished job posted before the isolation key existed leaves the stored isolation alone", ctx do
      pin_session!(ctx.card, "mac-1", "s-1", :exclusive)
      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")

      Repo.update_all(from(j in Schemas.NodeJob, where: j.id == ^turn.node_job_id),
        set: [payload: %{"turn_id" => turn.id, "prompt" => "one"}]
      )

      {:ok, _} = Runs.claim_next_job(ctx.runner)
      {:ok, _} = Talk.finish_turn(turn, :done, %{session_id: "s-9"})

      session = Talk.get_session(ctx.card)
      assert session.claude_session_id == "s-9"
      assert session.claude_session_isolation == :exclusive
    end

    test "a failed turn changes neither the session id nor its isolation", ctx do
      pin_session!(ctx.card, "mac-1", "s-1", :exclusive)
      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
      {:ok, _} = Runs.claim_next_job(ctx.runner)

      {:ok, _} = Talk.finish_turn(turn, :failed, %{session_id: "s-9"})

      session = Talk.get_session(ctx.card)
      assert session.claude_session_id == "s-1"
      assert session.claude_session_isolation == :exclusive
    end
  end

  describe "release_gone_pins/1 (RE493)" do
    @notice ~s(Runner "ghost-runner" is gone — this message starts a fresh session on the next available runner. It won't remember earlier turns.)

    setup do
      %{now: DateTime.truncate(DateTime.utc_now(), :second)}
    end

    # Scenario 1's setup: posted while the pin is live, then the holder "renamed" to a name with
    # no runners row — the case the post-time release cannot catch.
    defp queued_on_ghost!(ctx) do
      pin_session!(ctx.card, "mac-1", "sess-abc")
      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "hello")
      job = Runs.get_job(turn.node_job_id)
      assert job.runner_name == "mac-1"
      assert job.payload["resume_session"] == "sess-abc"

      Repo.update_all(from(j in Schemas.NodeJob, where: j.id == ^job.id), set: [runner_name: "ghost-runner"])
      pin_session!(ctx.card, "ghost-runner", "sess-abc")
      {turn, Runs.get_job(job.id)}
    end

    test "a queued turn pinned to a gone runner is released unpinned and fresh, with one notice", ctx do
      {turn, job} = queued_on_ghost!(ctx)
      card_id = ctx.card.id
      Talk.subscribe(card_id)
      Runs.subscribe(ctx.board.id)

      assert :ok = Talk.release_gone_pins(ctx.now)

      released = Runs.get_job(job.id)
      assert released.state == :queued
      assert released.runner_name == nil
      assert Map.has_key?(released.payload, "resume_session")
      assert released.payload["resume_session"] == nil
      assert released.payload["prompt"] == job.payload["prompt"]

      session = Talk.get_session(ctx.card)
      assert session.pinned_runner_name == nil
      assert session.claude_session_id == nil

      assert [%TalkEvent{kind: :error, client_seq: -1, text: @notice}] = error_events(turn)
      assert_receive {:talk_event, %TalkEvent{kind: :error, text: @notice}}
      assert_receive {:run_changed, ^card_id}
    end

    test "a second sweep is a no-op", ctx do
      {turn, _job} = queued_on_ghost!(ctx)
      :ok = Talk.release_gone_pins(ctx.now)
      Talk.subscribe(ctx.card.id)

      assert :ok = Talk.release_gone_pins(ctx.now)

      assert [_one] = error_events(turn)
      refute_receive {:talk_event, _}, 50
    end

    test "a claimed job whose runner is gone is untouched", ctx do
      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "hello")
      {:ok, _} = Runs.claim_next_job(ctx.runner)
      Repo.delete!(ctx.runner)

      assert :ok = Talk.release_gone_pins(ctx.now)

      job = Runs.get_job(turn.node_job_id)
      assert job.state == :claimed
      assert job.runner_name == "mac-1"
      assert error_events(turn) == []
    end

    test "a queued job pinned to a fresh runner is untouched", ctx do
      pin_session!(ctx.card, "mac-1", "sess-abc")
      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "hello")

      assert :ok = Talk.release_gone_pins(ctx.now)

      assert_pin_kept(ctx, turn)
    end

    test "a queued job pinned to a stale-but-not-gone runner is untouched", ctx do
      pin_session!(ctx.card, "mac-1", "sess-abc")
      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "hello")
      silence!(ctx.runner, 120)

      assert :ok = Talk.release_gone_pins(ctx.now)

      assert_pin_kept(ctx, turn)
    end

    test "an unpinned first-turn job is untouched", ctx do
      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "first")
      before = Runs.get_job(turn.node_job_id)
      assert before.runner_name == nil

      assert :ok = Talk.release_gone_pins(ctx.now)

      assert Runs.get_job(turn.node_job_id) == before
      assert error_events(turn) == []
    end

    test "release_talk_job/1 refuses a job revoked in the meantime", ctx do
      pin_session!(ctx.card, "ghost-runner", "sess-old")
      {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "hello")
      Repo.update_all(from(j in Schemas.NodeJob, where: j.id == ^turn.node_job_id), set: [runner_name: "ghost-runner"])
      job = Runs.get_job(turn.node_job_id)
      :ok = Runs.revoke_talk_job(job)

      assert {:error, :not_queued} = Runs.release_talk_job(job)
      assert Runs.get_job(job.id).runner_name == "ghost-runner"
    end

    test "a released job is claimable by another runner", ctx do
      {_turn, job} = queued_on_ghost!(ctx)
      :ok = Talk.release_gone_pins(ctx.now)

      mac2 =
        insert(:runner,
          board: ctx.board,
          name: "mac-2",
          capacity: %{"shared_clean" => 1, "exclusive" => 1},
          version: Runs.shared_talk_min_version()
        )

      job_id = job.id
      assert {:ok, %{id: ^job_id}} = Runs.claim_next_job(mac2)
    end

    defp assert_pin_kept(ctx, turn) do
      job = Runs.get_job(turn.node_job_id)
      assert job.state == :queued
      assert job.runner_name == "mac-1"
      assert job.payload["resume_session"] == "sess-abc"

      session = Talk.get_session(ctx.card)
      assert session.pinned_runner_name == "mac-1"
      assert session.claude_session_id == "sess-abc"
      assert error_events(turn) == []
    end
  end

  # The session's stored isolation defaults to `:shared_clean` — what a run-less card's turn is
  # chosen as (RE366) — so a pin test exercises the pin, not an isolation switch.
  defp pin_session!(card, runner_name, session_id, isolation \\ :shared_clean) do
    session = Talk.session_for_card(card)

    Repo.update_all(from(s in Schemas.TalkSession, where: s.id == ^session.id),
      set: [pinned_runner_name: runner_name, claude_session_id: session_id, claude_session_isolation: isolation]
    )
  end

  defp exclusive_run!(ctx) do
    flow = insert(:flow, board: ctx.board, isolation: :exclusive)
    insert(:run, card: ctx.card, flow_id: flow.id, status: :running)
  end

  defp turn_events(turn), do: Repo.all(from(e in TalkEvent, where: e.talk_turn_id == ^turn.id, order_by: e.seq))

  defp silence!(runner, seconds) do
    at = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -seconds, :second)
    Repo.update_all(from(r in Schemas.Runner, where: r.id == ^runner.id), set: [last_heartbeat: at])
  end

  defp error_events(turn) do
    Repo.all(from(e in TalkEvent, where: e.talk_turn_id == ^turn.id and e.kind == :error))
  end

  defp event(client_seq, kind, text) do
    %{"client_seq" => client_seq, "kind" => kind, "text" => text, "dim" => kind == "tool"}
  end
end
