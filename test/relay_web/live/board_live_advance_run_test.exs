defmodule RelayWeb.BoardLiveAdvanceRunTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Cards
  alias Relay.Repo
  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.SubTask

  setup :register_and_log_in_user

  setup %{user: user} do
    FakeDispatcher.register(self())
    board = Relay.Boards.get_or_create_default_board(user)
    start_engine!()
    %{board: board, flow: foreach_flow(board)}
  end

  defp foreach_flow(board) do
    pulls = Enum.find(board.stages, &(&1.name == "Next up"))
    works = Enum.find(board.stages, &(&1.name == "Spec"))
    lands = Enum.find(board.stages, &(&1.name == "Plan"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "advance-live-#{System.unique_integer([:positive])}",
        isolation: :shared_clean,
        pulls_from_stage_id: pulls.id,
        works_in_stage_id: works.id,
        lands_on_stage_id: lands.id,
        nodes: [
          %{key: "impl", type: :agent, run: "impl {ref}", expects_commits: true, foreach: "card.sub_tasks"},
          %{key: "review", type: :agent, run: "review {ref}"},
          %{key: "wrap", type: :shell, run: "true"}
        ],
        edges: [
          %{from: "start", to: "impl"},
          %{from: "impl", to: "review", on: :succeeded},
          %{from: "impl", to: "needs_input", on: :failed},
          %{from: "review", to: "impl", on: :failed, max_loops: 3},
          %{from: "review", to: "impl", on: :succeeded, when: :foreach_remaining},
          %{from: "review", to: "wrap", on: :succeeded, when: :foreach_exhausted},
          %{from: "wrap", to: "done", on: :succeeded}
        ]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  defp started(board, flow) do
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Cards.create_card(stage, %{title: "already committed"})
    tasks = for position <- 1..2, do: insert(:sub_task, card: card, position: position)
    {:ok, _run} = Runs.start_run(card, flow)
    %{card: card, tasks: tasks}
  end

  defp stuck(board, flow) do
    state = started(board, flow)
    assert_receive {:dispatched, %NodeJob{node_key: "impl"} = impl}
    {:ok, _run} = Runs.report_outcome(impl, %{outcome: :failed, detail: "already committed", git_sha: "moved99"})
    state
  end

  defp open(conn, board, card) do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}")
    render_async(view)
    view
  end

  test "a run parked on an already-committed task offers the advance control", ctx do
    %{card: card} = stuck(ctx.board, ctx.flow)
    view = open(ctx.conn, ctx.board, card)

    assert has_element?(view, "#run-advance")
    assert render(view) =~ "Task already done"
  end

  test "a live run does not", ctx do
    %{card: card} = started(ctx.board, ctx.flow)
    assert_receive {:dispatched, %NodeJob{}}

    refute has_element?(open(ctx.conn, ctx.board, card), "#run-advance")
  end

  test "clicking it checks the task off and rebinds the run to the next one", ctx do
    %{card: card, tasks: [first, second]} = stuck(ctx.board, ctx.flow)
    view = open(ctx.conn, ctx.board, card)

    view |> element("#run-advance") |> render_click()

    assert Repo.get!(SubTask, first.id).done == true
    assert_receive {:dispatched, %NodeJob{node_key: "impl"} = next}
    assert Repo.get!(NodeExecution, next.node_execution_id).sub_task_id == second.id
    refute has_element?(view, "#run-advance")
  end

  test "a refusal flashes the reason rather than failing silently", ctx do
    %{card: card} = stuck(ctx.board, ctx.flow)
    view = open(ctx.conn, ctx.board, card)
    view |> element("#run-advance") |> render_click()

    # The run is live again, so a second advance must refuse BY NAME.
    assert render_click(view, "advance_run", %{}) =~ "only a failed run"
  end
end
