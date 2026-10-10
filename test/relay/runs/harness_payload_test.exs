defmodule Relay.Runs.HarnessPayloadTest do
  @moduledoc """
  RE433 — every agent node resolves to a harness + model at enqueue. The job payload carries the
  harness command template, the model and the node's effort; the job row carries `harness_key`
  for claim routing. A red or unknown agent's job carries a `refusal` and is recorded `:blocked`
  without ever being dispatched.
  """
  use Relay.DataCase, async: true

  alias Relay.Agents
  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeExecution
  alias Schemas.NodeJob

  @red_detail ~s(agent "Gemini Pro" uses model "gemini-2.5-pro", which Gemini CLI no longer offers — pick a model in Settings → Agents)

  setup do
    FakeDispatcher.register(self())
    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Harness Board"})
    :ok = Runs.subscribe(board.id)
    start_engine!()
    %{board: board}
  end

  defp harness(board, key), do: Enum.find(Agents.list_harnesses(board), &(&1.key == key))

  defp agent!(board, name, harness_key, model) do
    {:ok, agent} =
      Agents.create_agent(board, %{"name" => name, "harness_id" => harness(board, harness_key).id, "model" => model})

    agent
  end

  # A stage holds one flow (RE429): take the seeded `spec` flow off Spec so the test flow works there.
  defp flow!(board, node) do
    {:ok, _} = Relay.Flows.delete_flow(Relay.Flows.get_flow!(board, "spec"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "harness-flow",
        isolation: :shared_clean,
        stage_id: spec.id,
        nodes: [Map.merge(%{key: "work", run: "/work {ref}", max_retries: 2}, node)],
        edges: [%{from: "start", to: "work"}, %{from: "work", to: "done", on: :succeeded}]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  defp card!(board) do
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Relay.Cards.create_card(stage, %{title: "Harness card"})
    card
  end

  defp start!(board, flow) do
    card = card!(board)
    {:ok, run} = Runs.start_run(card, flow)
    {card, run}
  end

  # Scenario 1
  test "a node inheriting the default runs on Claude Code with the board's command", %{board: board} do
    flow = flow!(board, %{type: :agent, llm: nil, effort: "high"})
    start!(board, flow)

    assert_receive {:dispatched, %NodeJob{payload: payload} = job}
    assert payload["harness"]["key"] == "claude-code"
    assert payload["harness"]["command"] == harness(board, "claude-code").command
    assert payload["model"] == "opus"
    assert payload["effort"] == "high"
    refute Map.has_key?(payload, "refusal")
    assert Repo.get!(NodeJob, job.id).harness_key == "claude-code"
  end

  # Scenario 2
  test "a node naming a Codex agent runs on Codex with that agent's model", %{board: board} do
    agent!(board, "Codex Fast", "codex", "gpt-6-sol")
    flow = flow!(board, %{type: :agent, llm: "Codex Fast"})
    start!(board, flow)

    assert_receive {:dispatched, %NodeJob{payload: payload} = job}
    assert payload["harness"]["key"] == "codex"
    assert payload["model"] == "gpt-6-sol"
    assert payload["harness"]["session_id_path"] == ".thread_id"
    assert Repo.get!(NodeJob, job.id).harness_key == "codex"
  end

  # Scenario 3
  test "a shell node carries no harness, model or effort", %{board: board} do
    flow = flow!(board, %{type: :shell, run: "mix precommit"})
    start!(board, flow)

    assert_receive {:dispatched, %NodeJob{payload: payload} = job}
    assert Map.fetch!(payload, "harness") == nil
    assert Map.fetch!(payload, "model") == nil
    assert Map.fetch!(payload, "effort") == nil
    assert Repo.get!(NodeJob, job.id).harness_key == nil
  end

  defp red_gemini_run!(board) do
    agent = agent!(board, "Gemini Pro", "gemini-cli", "gemini-2.5-pro")
    flow = flow!(board, %{type: :agent, llm: "Gemini Pro"})
    {:ok, _} = Agents.update_harness(harness(board, "gemini-cli"), %{"models" => ["gemini-2.5-flash"]})
    {card, run} = start!(board, flow)
    assert_receive {:run_parked, _run}, 2_000
    {agent, card, run}
  end

  # Scenario 4
  test "a red agent's node is recorded blocked without dispatching anything", %{board: board} do
    {_agent, card, run} = red_gemini_run!(board)

    refute_receive {:dispatched, _}

    run = Runs.get_run!(run.id)
    assert run.status == :parked

    executions = Repo.all(from e in NodeExecution, where: e.run_id == ^run.id)
    assert [%NodeExecution{outcome: :blocked, detail: @red_detail}] = executions
    assert Repo.aggregate(from(j in NodeJob, where: j.run_id == ^run.id), :count) == 1

    card = Repo.get!(Schemas.Card, card.id)
    assert card.status == :needs_input
    assert Enum.any?(Relay.Activity.list_timeline(card), &(Map.get(&1, :text) == @red_detail))
  end

  # Scenario 5
  test "fixing the red agent and retrying dispatches the node with the new model", %{board: board} do
    {agent, _card, run} = red_gemini_run!(board)

    {:ok, _} = Agents.update_agent(agent, %{"model" => "gemini-2.5-flash"})
    assert {:ok, _revived} = Runs.retry_run(Runs.get_run!(run.id))

    assert_receive {:dispatched, %NodeJob{payload: payload}}
    assert payload["model"] == "gemini-2.5-flash"
    refute Map.has_key?(payload, "refusal")
  end

  # Scenario 6
  test "build_payload seeds a never-seeded board before resolving its default" do
    board = insert(:board)
    stage = insert(:stage, board: board)
    card = insert(:card, board: board, stage: stage)
    run = insert(:run, card: card)
    node = %Schemas.Flow.Node{key: "work", type: :agent, run: "/work {ref}"}
    flow = %Schemas.Flow{board_id: board.id, isolation: :shared_clean, nodes: [node]}

    payload = Runs.build_payload(run, flow, "work", [])

    assert Agents.default_agent(board)
    assert payload["model"] == "opus"
  end
end
