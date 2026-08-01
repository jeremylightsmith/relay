defmodule Mix.Tasks.Relay.PublishConfigTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Relay.PublishConfig

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    capture_io(fn -> PublishConfig.run([tmp_dir]) end)
    {:ok, manifest: Jason.decode!(File.read!(Path.join(tmp_dir, "manifest.json")))}
  end

  test "the manifest lists every tooling skill", %{manifest: manifest} do
    srcs = Enum.map(manifest["items"], & &1["src"])

    for skill <- PublishConfig.tooling_skills() do
      assert ".claude/skills/#{skill}/SKILL.md" in srcs
    end
  end

  test "every tooling skill is copied into the generated tree", %{tmp_dir: tmp_dir} do
    for skill <- PublishConfig.tooling_skills() do
      assert File.regular?(Path.join(tmp_dir, ".claude/skills/#{skill}/SKILL.md"))
    end
  end

  test "relay-onboard ships alongside the doctor it loops on", %{tmp_dir: tmp_dir} do
    skills = tmp_dir |> Path.join(".claude/skills") |> File.ls!()

    assert "relay-onboard" in skills
    assert "relay-doctor" in skills
    assert "writing-skills" in skills
  end

  test "the manifest pins executor.version to bin/relay's EXECUTOR_VERSION", %{manifest: manifest} do
    [_, version] = Regex.run(~r/^EXECUTOR_VERSION\s*=\s*(\d+)/m, File.read!("bin/relay"))

    assert manifest["executor"]["version"] == String.to_integer(version)
  end
end
