defmodule Relay.Runs.HarnessClaimTest do
  @moduledoc """
  RE433 — a runner only claims a node whose harness it has installed (a runner that never
  reported its harnesses is assumed to have only the legacy `claude-code`), and nobody ever
  claims a job carrying a `refusal`.
  """
  use Relay.DataCase, async: true

  alias Relay.Runs
  alias Schemas.NodeJob

  setup do
    board = insert(:board)
    stage = insert(:stage, board: board)
    %{board: board, stage: stage}
  end

  defp queued_job!(ctx, harness_key, extra \\ %{}) do
    card = insert(:card, board: ctx.board, stage: ctx.stage)
    run = insert(:run, card: card)
    execution = insert(:node_execution, run: run, outcome: nil, finished_at: nil)

    payload =
      Map.merge(
        %{
          "isolation" => "shared_clean",
          "harness" => harness_key && %{"key" => harness_key},
          "vars" => %{"ref" => "RL-#{card.ref_number}"}
        },
        extra
      )

    insert(:node_job,
      node_execution: execution,
      state: :queued,
      runner_name: Map.get(extra, :runner_name),
      claimed_at: nil,
      payload: Map.delete(payload, :runner_name),
      harness_key: harness_key
    )
  end

  defp runner!(ctx, harnesses, name \\ "mac-1") do
    insert(:runner, board: ctx.board, name: name, harnesses: harnesses)
  end

  # Scenario 7
  test "a runner skips a job whose harness it has not installed", ctx do
    codex = queued_job!(ctx, "codex")
    claude = queued_job!(ctx, "claude-code")
    assert codex.id < claude.id

    runner =
      runner!(ctx, [%{"key" => "claude-code", "installed" => true}, %{"key" => "codex", "installed" => false}])

    assert {:ok, %NodeJob{id: id}} = Runs.claim_next_job(runner)
    assert id == claude.id
    assert {:ok, nil} = Runs.claim_next_job(runner)
    assert Repo.get!(NodeJob, codex.id).state == :queued
  end

  # Scenario 8
  test "a runner that never reported harnesses claims claude-code and shell jobs but not codex", ctx do
    codex = queued_job!(ctx, "codex")
    claude = queued_job!(ctx, "claude-code")
    shell = queued_job!(ctx, nil)
    runner = runner!(ctx, nil)

    assert {:ok, %NodeJob{id: first}} = Runs.claim_next_job(runner)
    assert {:ok, %NodeJob{id: second}} = Runs.claim_next_job(runner)
    assert {:ok, nil} = Runs.claim_next_job(runner)
    assert Enum.sort([first, second]) == Enum.sort([claude.id, shell.id])
    assert Repo.get!(NodeJob, codex.id).state == :queued
  end

  # Scenario 9
  test "a refused job is never claimed, even pinned to a runner with every harness", ctx do
    all =
      for key <- ["claude-code", "codex", "gemini-cli"], do: %{"key" => key, "installed" => true}

    runner = runner!(ctx, all)

    refused =
      queued_job!(ctx, "gemini-cli", %{"refusal" => "agent is red", :runner_name => runner.name})

    assert refused.runner_name == runner.name
    assert {:ok, nil} = Runs.claim_next_job(runner)
    assert Repo.get!(NodeJob, refused.id).state == :queued
  end

  # Scenario 10
  test "a codex job pinned to a runner without codex installed is not claimed by it", ctx do
    runner = runner!(ctx, [%{"key" => "claude-code", "installed" => true}])
    pinned = queued_job!(ctx, "codex", %{:runner_name => runner.name})

    assert pinned.runner_name == runner.name
    assert {:ok, nil} = Runs.claim_next_job(runner)
  end
end
