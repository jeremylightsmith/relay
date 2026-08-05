defmodule Relay.TalkTest do
  @moduledoc """
  RE268 — the transcript store's promises (ADR 0009 § Testing): `seq` strictly increasing with
  no gaps, a replayed batch stores and broadcasts nothing new, `clear/1` hides without
  deleting, Stop revokes, and posting a turn creates a claimable talk job.
  """
  use Relay.DataCase, async: true

  alias Relay.Runs
  alias Relay.Talk
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

    author = insert(:user)

    executor =
      insert(:executor,
        board: board,
        name: "mac-1",
        capacity: %{"exclusive" => 1},
        version: Runs.min_talk_executor_version()
      )

    %{board: board, card: card, author: author, executor: executor}
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

    assert {:ok, claimed} = Runs.claim_next_job(ctx.executor)
    assert claimed.id == job.id
  end

  # RE268 whole-branch review — `:claimed` was a documented-but-unreachable status: a turn stayed
  # `:queued` for its whole life, including while `claude -p` ran, falsifying five doc lines.
  test "claiming a turn's job moves the turn to :claimed and broadcasts it", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "why is this stuck?")
    Talk.subscribe(ctx.card.id)

    {:ok, job} = Runs.claim_next_job(ctx.executor)
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
    {:ok, _} = Talk.append_events(turn, [event(1, "tool", "Read · lib/relay.ex"), event(2, "out", "answer")])
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

  test "finishing a turn persists the claude session id and pins the executor", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
    {:ok, _claimed} = Runs.claim_next_job(ctx.executor)

    {:ok, done} = Talk.finish_turn(turn, :done, %{session_id: "sess-abc"})
    assert done.status == :done

    session = Talk.session_for_card(ctx.card)
    assert session.claude_session_id == "sess-abc"
    assert session.pinned_executor_name == "mac-1"
    assert Runs.get_job(turn.node_job_id).state == :done
  end

  test "the next turn resumes the stored session and is pinned to its holder", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
    {:ok, _} = Runs.claim_next_job(ctx.executor)
    {:ok, _} = Talk.finish_turn(turn, :done, %{session_id: "sess-abc"})

    {:ok, two} = Talk.post_message(ctx.card, ctx.author, "two")
    job = Runs.get_job(two.node_job_id)

    assert job.payload["resume_session"] == "sess-abc"
    assert job.executor_name == "mac-1"
  end

  test "stop revokes the job, ends the turn non-error, and keeps the partial output", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
    {:ok, _} = Runs.claim_next_job(ctx.executor)
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
    assert Relay.Repo.aggregate(TalkEvent, :count) == 2
  end

  test "a talk turn is claimable while a node job is live on the same card", ctx do
    run = insert(:run, card: ctx.card)
    execution = insert(:node_execution, run: run)
    node_job = Runs.insert_job!(run, execution, %{"isolation" => "exclusive"})

    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "what is happening?")

    assert {:ok, first} = Runs.claim_next_job(ctx.executor)
    assert first.id == node_job.id
    assert {:ok, second} = Runs.claim_next_job(ctx.executor)
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
    {:ok, _claimed} = Runs.claim_next_job(ctx.executor)

    {:ok, stopped} = Talk.finish_turn(turn, :stopped)
    assert stopped.status == :stopped

    session = Talk.session_for_card(ctx.card)
    assert session.claude_session_id == nil
    assert session.pinned_executor_name == nil
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

  test "a line whose kind is not a string is dropped without failing the batch", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
    bad = %{"client_seq" => 4, "kind" => %{"nope" => true}, "text" => "hi", "dim" => false}

    assert {:ok, stored} = Talk.append_events(turn, [bad, event(1, "out", "good")])
    assert Enum.map(stored, & &1.text) == ["good"]
  end

  test "a turn ended by Stop is not resurrected as :done by a late outcome", ctx do
    {:ok, turn} = Talk.post_message(ctx.card, ctx.author, "one")
    {:ok, stopped} = Talk.stop_turn(turn)

    assert {:ok, still} = Talk.finish_turn(stopped, :done, %{session_id: "sess-late"})
    assert still.status == :stopped
    assert Talk.session_for_card(ctx.card).claude_session_id == nil
    assert Talk.session_for_card(ctx.card).pinned_executor_name == nil
  end

  test "a replayed outcome POST does not rewrite the session or re-broadcast", ctx do
    {:ok, _queued} = Talk.post_message(ctx.card, ctx.author, "one")
    {:ok, job} = Runs.claim_next_job(ctx.executor)
    {:ok, turn} = Talk.mark_claimed(job)

    {:ok, done} = Talk.finish_turn(turn, :done, %{session_id: "sess-1"})
    Talk.subscribe(ctx.card.id)

    assert {:ok, again} = Talk.finish_turn(done, :failed, %{detail: "late"})
    assert again.status == :done
    refute_receive {:talk_turn_changed, _}, 50
    assert Talk.session_for_card(ctx.card).claude_session_id == "sess-1"
  end

  defp event(client_seq, kind, text) do
    %{"client_seq" => client_seq, "kind" => kind, "text" => text, "dim" => kind == "tool"}
  end
end
