defmodule Relay.RelayConfigTest do
  use ExUnit.Case, async: true

  @config_path Path.join(File.cwd!(), "relay_config.json")

  setup do
    config = @config_path |> File.read!() |> Jason.decode!()
    stages = Map.new(config["pipeline"], fn stage -> {stage["stage"], stage} end)
    {:ok, config: config, stages: stages}
  end

  defp claude_steps(stage), do: for(%{"claude" => c} <- stage["action"], do: c)
  defp shell_steps(stage), do: for(%{"shell" => s} <- stage["action"], do: s)

  test "the config parses as JSON with a pipeline", %{config: config} do
    assert is_list(config["pipeline"])
  end

  test "the pipeline no longer has a Spec stage (cut over to the engine-driven flow, RLY-136)",
       %{stages: stages} do
    refute Map.has_key?(stages, "Spec")
  end

  test "Plan stage invokes /write-plan with the card ref", %{stages: stages} do
    assert Enum.any?(claude_steps(stages["Plan"]), &(&1 =~ "/write-plan {ref}"))
  end

  test "Code stage invokes /exec-plan with the card ref", %{stages: stages} do
    assert Enum.any?(claude_steps(stages["Code"]), &(&1 =~ "/exec-plan {ref}"))
  end

  test "Code stage no longer shells the card plan into plan.md", %{stages: stages} do
    refute Enum.any?(shell_steps(stages["Code"]), &(&1 =~ "plan.md"))
  end

  test "Code stage keeps the git branch, push, and PR shell steps", %{stages: stages} do
    shells = shell_steps(stages["Code"])
    assert Enum.any?(shells, &(&1 =~ "git checkout -B {branch}"))
    assert Enum.any?(shells, &(&1 =~ "git push -u origin {branch}"))
    assert Enum.any?(shells, &(&1 =~ "gh pr create"))
  end

  test "Code stage finishes by squash-merging the PR", %{stages: stages} do
    assert List.last(shell_steps(stages["Code"])) =~ "gh pr merge {branch} --squash"
  end

  test "the pipeline has no Deploy stage", %{stages: stages} do
    refute Map.has_key?(stages, "Deploy")
  end
end
