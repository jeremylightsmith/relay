defmodule RelayWeb.BoardLiveSubstatesTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Relay.Boards.get_or_create_default_board(user)
    stages = board.stages
    ai_work = Enum.find(stages, &(&1.type == :work and &1.ai_enabled))
    human_stage = Enum.find(stages, &(&1.type == :queue))
    review = Enum.find(stages, &(&1.type == :review))
    done = Relay.Boards.terminal_stage(stages)
    %{board: board, ai_work: ai_work, human_stage: human_stage, review: review, done: done}
  end

  test "amber appears on exactly needs_input and in_review cards", ctx do
    %{conn: conn, board: board} = ctx
    ni = insert(:card, board: board, stage: ctx.ai_work, status: :needs_input)
    ir = insert(:card, board: board, stage: ctx.review, status: :in_review)
    ready = insert(:card, board: board, stage: ctx.ai_work, status: :ready)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    assert has_element?(view, ~s(article[data-ref="RLY-#{ni.ref_number}"].border-l-warning))
    assert has_element?(view, ~s(article[data-ref="RLY-#{ir.ref_number}"].border-l-warning))
    refute has_element?(view, ~s(article[data-ref="RLY-#{ready.ref_number}"].border-l-warning))
  end

  test "a ready-awaiting-human card shows no amber", ctx do
    %{conn: conn, board: board} = ctx
    # a ready card parked in the first queue whose next stage is not AI-enabled: quiet.
    awaiting = insert(:card, board: board, stage: ctx.human_stage, status: :ready)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    refute has_element?(view, ~s(article[data-ref="RLY-#{awaiting.ref_number}"].border-l-warning))
  end

  test "a ready card at the terminal stage renders as Done", ctx do
    %{conn: conn, board: board} = ctx
    card = insert(:card, board: board, stage: ctx.done, status: :ready)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    assert has_element?(view, ~s(article[data-ref="RLY-#{card.ref_number}"][data-done="true"]))
  end

  test "the drawer banner switches across all four states", ctx do
    %{conn: conn, board: board} = ctx

    for {stage, status, sel} <- [
          {ctx.ai_work, :working, "#working-strip"},
          {ctx.ai_work, :needs_input, "#needs-input-panel"},
          {ctx.review, :in_review, "#review-panel"},
          {ctx.done, :ready, "#drawer-done-pill"}
        ] do
      card = insert(:card, board: board, stage: stage, status: status)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-#{card.ref_number}")
      render_async(view)
      assert has_element?(view, sel)
    end
  end
end
