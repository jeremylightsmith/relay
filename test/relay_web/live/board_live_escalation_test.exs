defmodule RelayWeb.BoardLiveEscalationTest do
  @moduledoc """
  RE253 — a `needs_input` park raised by the ENGINE (a node failed and the flow's
  `--on failed --> needs_input` edge escalated it, failure mode A4) must be answerable. Before this
  card the drawer swapped the answer form for a red "⊗ AGENT STOPPED" banner with no input field,
  so every escalation was a dead end.
  """
  use RelayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Relay.Activity
  alias Relay.Cards
  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeJob

  setup :register_and_log_in_user

  setup %{user: user} do
    FakeDispatcher.register(self())
    board = Relay.Boards.get_or_create_default_board(user)
    flow = park_flow(board)
    start_supervised!(Relay.Runs.Supervisor)
    %{board: board, flow: flow}
  end

  # A flow whose failed edge parks on needs_input (RLY-194 shape): a reported :failed makes an
  # escalation park; a reported :needs_input makes a genuine question.
  defp park_flow(board) do
    next_up = Enum.find(board.stages, &(&1.name == "Next up"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    review = Enum.find(board.stages, &(&1.name == "Spec:Review"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "park-flow",
        isolation: :shared_clean,
        pulls_from_stage_id: next_up.id,
        works_in_stage_id: spec.id,
        lands_on_stage_id: review.id,
        nodes: [%{key: "brainstorm", type: :agent, run: "/brainstorm {ref}"}],
        edges: [
          %{from: "start", to: "brainstorm"},
          %{from: "brainstorm", to: "done", on: :succeeded},
          %{from: "brainstorm", to: "needs_input", on: :failed}
        ]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  # Returns {card, run}; the run id is captured so the click assertion needs no ref re-resolution.
  defp park(board, flow, title, outcome, detail) do
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Cards.create_card(stage, %{title: title})
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{} = job}
    {:ok, _run} = Runs.report_outcome(job, %{outcome: outcome, detail: detail, session_id: "s"})
    {card, run}
  end

  defp open(conn, board, card) do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}")
    render_async(view)
    view
  end

  @guard "✗ commit guard: the working tree is dirty after `mix precommit`"

  test "an escalation park is answerable and shows the failure output", ctx do
    {card, _run} = park(ctx.board, ctx.flow, "Commit guard", :failed, @guard)
    view = open(ctx.conn, ctx.board, card)

    # the Run tab's copy — the one the drawer opens on for a parked run
    assert has_element?(view, "#run-needs-input-panel", "NODE FAILED · YOUR CALL")
    assert has_element?(view, "#run-needs-input-panel", "brainstorm")
    assert has_element?(view, "#run-needs-input-failure-detail", "commit guard")
    assert has_element?(view, "#run-needs-input-answer")
    assert has_element?(view, "#run-needs-input-send")
    assert has_element?(view, "#run-needs-input-retry")

    # the dead end is gone
    refute has_element?(view, "#run-stopped-banner")
    refute has_element?(view, "#run-restart")
    refute render(view) =~ "AGENT STOPPED"
  end

  test "the panel renders on the Detail tab too, with distinct ids", ctx do
    {card, _run} = park(ctx.board, ctx.flow, "Commit guard", :failed, @guard)
    view = open(ctx.conn, ctx.board, card)

    assert has_element?(view, "#needs-input-panel")
    assert has_element?(view, "#run-needs-input-panel")
    assert has_element?(view, "#needs-input-retry")
    assert has_element?(view, "#run-needs-input-retry")
  end

  test "answering an escalation park unblocks the card and records the note", ctx do
    {card, _run} = park(ctx.board, ctx.flow, "Commit guard", :failed, @guard)
    view = open(ctx.conn, ctx.board, card)

    view
    |> form("#run-needs-input-form", answer: %{body: "try running the formatter first"})
    |> render_submit()

    reloaded = Cards.get_card(ctx.board, card.id)
    refute reloaded.status == :needs_input
    assert Enum.any?(Activity.list_conversation(reloaded), &(&1.body =~ "formatter"))
  end

  test "clicking Retry revives the run in place and clears the card's block", ctx do
    {card, run} = park(ctx.board, ctx.flow, "Commit guard", :failed, @guard)
    view = open(ctx.conn, ctx.board, card)

    view |> element("#run-needs-input-retry") |> render_click()

    assert Runs.get_run!(run.id).status == :running
    assert Cards.get_card(ctx.board, card.id).status == :working
    assert_receive {:dispatched, %NodeJob{node_key: "brainstorm"}}
  end

  test "a genuine question keeps today's face, with no Retry and no escalation copy", ctx do
    {card, _run} = park(ctx.board, ctx.flow, "Real question", :needs_input, "Which auth model?")
    view = open(ctx.conn, ctx.board, card)

    assert has_element?(view, "#run-needs-input-panel", "RELAY AI NEEDS YOUR INPUT")
    assert has_element?(view, "#run-needs-input-question", "Which auth model?")
    refute has_element?(view, "#run-needs-input-retry")
    refute has_element?(view, "#run-needs-input-failure-detail")
    refute render(view) =~ "NODE FAILED"
  end
end
