defmodule RelayWeb.BoardLiveRestartStalledTest do
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

  defp park(board, flow, title, outcome) do
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Cards.create_card(stage, %{title: title})
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{} = job}
    {:ok, _run} = Runs.report_outcome(job, %{outcome: outcome, detail: "x", session_id: "s"})
    run
  end

  test "the header control shows the stalled count and bulk-revives on click", ctx do
    died = park(ctx.board, ctx.flow, "Died A", :failed)
    died2 = park(ctx.board, ctx.flow, "Died B", :failed)
    ask = park(ctx.board, ctx.flow, "Real question", :needs_input)

    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")

    assert has_element?(view, "#restart-stalled-button", "2")

    view |> element("#restart-stalled-button") |> render_click()

    assert Runs.get_run!(died.id).status == :running
    assert Runs.get_run!(died2.id).status == :running
    assert Runs.get_run!(ask.id).status == :parked
    refute has_element?(view, "#restart-stalled-button")
  end

  test "the control is hidden when nothing is stalled", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")
    refute has_element?(view, "#restart-stalled-button")
  end
end
