defmodule RelayWeb.BoardLiveRestartTest do
  use RelayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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

  # A flow whose failed edge parks on needs_input (RLY-194 shape): a reported :failed makes a
  # died-agent park; a reported :needs_input makes a genuine question.
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

  test "a died-agent park shows the honest Restart banner, not the question form", ctx do
    {card, _run} = park(ctx.board, ctx.flow, "Agent died", :failed, "spend limit")
    view = open(ctx.conn, ctx.board, card)

    assert has_element?(view, "#run-restart")
    assert has_element?(view, "#run-stopped-banner", "Agent stopped")
    refute has_element?(view, "#needs-input-panel")
  end

  test "clicking Restart revives the run in place", ctx do
    {card, run} = park(ctx.board, ctx.flow, "Agent died", :failed, "spend limit")
    view = open(ctx.conn, ctx.board, card)

    view |> element("#run-restart") |> render_click()

    assert Runs.get_run!(run.id).status == :running
    assert_receive {:dispatched, %NodeJob{node_key: "brainstorm"}}
  end

  test "a genuine question still shows the question form, no Restart banner", ctx do
    {card, _run} = park(ctx.board, ctx.flow, "Real question", :needs_input, "Which auth model?")
    view = open(ctx.conn, ctx.board, card)

    assert has_element?(view, "#needs-input-panel")
    refute has_element?(view, "#run-restart")
  end
end
