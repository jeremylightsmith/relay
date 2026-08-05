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
    executor = insert(:executor, board: board, name: "mac-1", capacity: %{"exclusive" => 1})
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

  defp event(client_seq, kind, text) do
    %{"client_seq" => client_seq, "kind" => kind, "text" => text, "dim" => kind == "tool"}
  end
end
