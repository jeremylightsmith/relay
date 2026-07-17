defmodule Relay.CardDerivationsTest do
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Cards

  # A board with a realistic pipeline; each stage is persisted so ids/positions are real.
  setup do
    board = insert(:board, key: "RLY")
    queue = insert(:stage, board: board, position: 1, category: :unstarted, type: :queue, ai_enabled: false)
    ai_work = insert(:stage, board: board, position: 2, category: :in_progress, type: :work, ai_enabled: true)
    human_work = insert(:stage, board: board, position: 3, category: :in_progress, type: :work, ai_enabled: false)
    review = insert(:stage, board: board, position: 4, category: :in_progress, type: :review, ai_enabled: false)
    done = insert(:stage, board: board, position: 5, category: :complete, type: :done, ai_enabled: false)

    done_sublane =
      insert(:stage,
        board: board,
        parent_id: human_work.id,
        position: 6,
        category: :in_progress,
        type: :done,
        ai_enabled: false
      )

    stages = [queue, ai_work, human_work, review, done, done_sublane]

    %{
      board: board,
      stages: stages,
      queue: queue,
      ai_work: ai_work,
      human_work: human_work,
      review: review,
      done: done,
      done_sublane: done_sublane
    }
  end

  describe "terminal_stage/1" do
    test "is the last top-level stage by position", %{stages: stages, done: done} do
      assert Boards.terminal_stage(stages).id == done.id
    end

    test "ignores sub-lanes and is nil for an empty list" do
      assert Boards.terminal_stage([]) == nil
    end
  end

  describe "done?/2" do
    test "ready at the terminal stage is done", ctx do
      card = insert(:card, board: ctx.board, stage: ctx.done, status: :ready)
      assert Cards.done?(card, ctx.stages)
    end

    test "ready in a mid-board Done sub-lane is NOT done", ctx do
      card = insert(:card, board: ctx.board, stage: ctx.done_sublane, status: :ready)
      refute Cards.done?(card, ctx.stages)
    end

    test "a non-ready card at the terminal stage is not done", ctx do
      card = insert(:card, board: ctx.board, stage: ctx.done, status: :working)
      refute Cards.done?(card, ctx.stages)
    end
  end

  describe "ready_awaiting_human?/2" do
    test "ready in an AI work stage is ambient (false)", ctx do
      card = insert(:card, board: ctx.board, stage: ctx.ai_work, status: :ready)
      refute Cards.ready_awaiting_human?(card, ctx.stages)
    end

    test "ready in a human work stage is awaiting-human (true)", ctx do
      card = insert(:card, board: ctx.board, stage: ctx.human_work, status: :ready)
      assert Cards.ready_awaiting_human?(card, ctx.stages)
    end

    test "ready in a queue whose next column is AI is ambient (false)", ctx do
      card = insert(:card, board: ctx.board, stage: ctx.queue, status: :ready)
      refute Cards.ready_awaiting_human?(card, ctx.stages)
    end

    test "ready at the terminal stage is not awaiting-human (it is Done)", ctx do
      card = insert(:card, board: ctx.board, stage: ctx.done, status: :ready)
      refute Cards.ready_awaiting_human?(card, ctx.stages)
    end

    test "a non-ready card is never awaiting-human", ctx do
      card = insert(:card, board: ctx.board, stage: ctx.human_work, status: :working)
      refute Cards.ready_awaiting_human?(card, ctx.stages)
    end
  end

  describe "needs_you?/2" do
    test "needs_input and in_review always count", ctx do
      ni = insert(:card, board: ctx.board, stage: ctx.ai_work, status: :needs_input)
      ir = insert(:card, board: ctx.board, stage: ctx.review, status: :in_review)
      assert Cards.needs_you?(ni, ctx.stages)
      assert Cards.needs_you?(ir, ctx.stages)
    end

    test "ready-awaiting-human counts; ambient ready does not", ctx do
      awaiting = insert(:card, board: ctx.board, stage: ctx.human_work, status: :ready)
      ambient = insert(:card, board: ctx.board, stage: ctx.ai_work, status: :ready)
      assert Cards.needs_you?(awaiting, ctx.stages)
      refute Cards.needs_you?(ambient, ctx.stages)
    end
  end

  describe "needs_you_rollup/1" do
    test "counts the three buckets across the board", ctx do
      insert(:card, board: ctx.board, stage: ctx.ai_work, status: :needs_input)
      insert(:card, board: ctx.board, stage: ctx.review, status: :in_review)
      insert(:card, board: ctx.board, stage: ctx.human_work, status: :ready)
      insert(:card, board: ctx.board, stage: ctx.ai_work, status: :ready)
      insert(:card, board: ctx.board, stage: ctx.done, status: :ready)

      assert Cards.needs_you_rollup(ctx.board) == %{
               needs_input: 1,
               in_review: 1,
               awaiting_human: 1,
               agent_stalled: 0
             }
    end

    # RLY-148: dead agents float up in triage. Health here must be derived exactly as
    # the board renders it (newest entry vs heartbeat · active AI owner · AI-enabled stage).
    test "a stopped agent card counts in agent_stalled", ctx do
      card = insert(:card, board: ctx.board, stage: ctx.ai_work, status: :working)
      insert(:card_owner, card: card)
      insert(:activity, card: card, type: :failure, text: "agent stopped")

      assert Cards.needs_you_rollup(ctx.board) == %{
               needs_input: 0,
               in_review: 0,
               awaiting_human: 0,
               agent_stalled: 1
             }
    end

    test "a quiet agent card past STALE_AFTER counts in agent_stalled", ctx do
      card = insert(:card, board: ctx.board, stage: ctx.ai_work, status: :working)
      insert(:card_owner, card: card)
      quiet = DateTime.utc_now() |> DateTime.add(-3 * 60, :second) |> DateTime.truncate(:second)
      insert(:activity, card: card, type: :action, text: "reindexing 12k documents", inserted_at: quiet)

      assert Cards.needs_you_rollup(ctx.board).agent_stalled == 1
    end

    test "a live agent card does not count", ctx do
      card = insert(:card, board: ctx.board, stage: ctx.ai_work, status: :working)
      insert(:card_owner, card: card)
      insert(:activity, card: card, type: :action, text: "uploaded 24/40 posts")

      assert Cards.needs_you_rollup(ctx.board).agent_stalled == 0
    end

    test "a blocked card with a dead agent counts once, in needs_input", ctx do
      card = insert(:card, board: ctx.board, stage: ctx.ai_work, status: :needs_input)
      insert(:card_owner, card: card)
      insert(:activity, card: card, type: :failure, text: "agent stopped")

      assert Cards.needs_you_rollup(ctx.board) == %{
               needs_input: 1,
               in_review: 0,
               awaiting_human: 0,
               agent_stalled: 0
             }
    end
  end

  describe "needs_input_questions/1" do
    test "maps needs_input card ids to their latest question", %{board: board, ai_work: ai_work} do
      card = insert(:card, board: board, stage: ai_work, status: :needs_input)

      insert(:activity,
        card: card,
        type: :needs_input,
        meta: %{"question" => "First?"},
        inserted_at: ~U[2026-07-01 00:00:00Z]
      )

      insert(:activity,
        card: card,
        type: :needs_input,
        meta: %{"question" => "Latest?"},
        inserted_at: ~U[2026-07-02 00:00:00Z]
      )

      other = insert(:card, board: board, stage: ai_work, status: :working)
      insert(:activity, card: other, type: :needs_input, meta: %{"question" => "stale"})

      map = Cards.needs_input_questions(board)
      assert map[card.id] == "Latest?"
      refute Map.has_key?(map, other.id)
    end
  end
end
