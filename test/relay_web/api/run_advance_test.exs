defmodule RelayWeb.Api.RunAdvanceTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Cards
  alias Relay.Repo
  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeJob
  alias Schemas.SubTask

  setup %{conn: conn} do
    FakeDispatcher.register(self())

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "API Advance Board"})
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, user)
    start_engine!()

    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> token), board: board}
  end

  defp foreach_flow(board) do
    pulls = Enum.find(board.stages, &(&1.name == "Next up"))
    works = Enum.find(board.stages, &(&1.name == "Spec"))
    lands = Enum.find(board.stages, &(&1.name == "Plan"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "advance-api-#{System.unique_integer([:positive])}",
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
    {:ok, card} = Cards.create_card(stage, %{title: "advance me"})
    tasks = for position <- 1..2, do: insert(:sub_task, card: card, position: position)
    {:ok, run} = Runs.start_run(card, flow)
    %{run: run, card: card, tasks: tasks}
  end

  defp stuck(board, flow) do
    state = started(board, flow)
    assert_receive {:dispatched, %NodeJob{node_key: "impl"} = impl}
    {:ok, run} = Runs.report_outcome(impl, %{outcome: :failed, detail: "already committed", git_sha: "moved99"})
    %{state | run: Runs.get_run!(run.id)}
  end

  test "POST /api/runs/:id/advance checks the task off and revives the run", ctx do
    %{run: run, tasks: [first, _second]} = stuck(ctx.board, foreach_flow(ctx.board))

    body = ctx.conn |> post(~p"/api/runs/#{run.id}/advance", %{}) |> json_response(200) |> Map.fetch!("data")

    assert body["status"] == "ok"
    assert body["run_id"] == run.id
    assert body["node"] == "impl"
    assert body["retries"] == 1
    assert Repo.get!(SubTask, first.id).done == true
  end

  test "POST /api/cards/:ref/advance resolves the card's newest run", ctx do
    %{run: run, card: card} = stuck(ctx.board, foreach_flow(ctx.board))

    body =
      ctx.conn
      |> post(~p"/api/cards/#{Cards.ref(ctx.board, card)}/advance", %{})
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["run_id"] == run.id
  end

  test "a refusal is a 422 naming the reason", ctx do
    %{run: run} = started(ctx.board, foreach_flow(ctx.board))
    assert_receive {:dispatched, %NodeJob{}}

    error = ctx.conn |> post(~p"/api/runs/#{run.id}/advance", %{}) |> json_response(422) |> Map.fetch!("error")

    assert error["code"] == "not_advanceable"
    assert error["message"] =~ "running"
  end

  test "another board's run is a 404, never a refusal", ctx do
    other_user = insert(:user)
    {:ok, other_board} = Relay.Boards.create_board(other_user, %{name: "Elsewhere"})
    %{run: run} = stuck(other_board, foreach_flow(other_board))

    assert ctx.conn |> post(~p"/api/runs/#{run.id}/advance", %{}) |> json_response(404)
  end
end
