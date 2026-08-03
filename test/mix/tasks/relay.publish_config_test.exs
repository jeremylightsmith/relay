defmodule Mix.Tasks.Relay.PublishConfigTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Relay.PublishConfig
  alias Relay.Runs.PublishMarker

  @moduletag :tmp_dir

  # RE185 review (round 2): publishing writes a `.relay/published.json` marker at `src`.
  # Publishing straight from `File.cwd!()` would make every test run write THIS repo's TRACKED
  # marker — a hard-killed `mix test` would then leave the working tree claiming a version was
  # published when it wasn't. So `src` is a scratch copy, never `File.cwd!()`.
  #
  # That copy must stay narrow: `.claude/worktrees` (where the executor itself runs) lives
  # under `.claude/` in this repo and can be gigabytes — copying `.claude` wholesale, once per
  # test, turned a review fix into a disk-filling regression. Copy only what `publish/2` reads
  # (`lib/mix/tasks/relay.publish_config.ex:127-146`) and build it once in `setup_all`, not per
  # test — `.claude/agents`, `.claude/commands`, and `.claude/skills` alone are under 200K.
  #
  # RE185 review (round 3): the destination must be unique per test run, not a fixed
  # machine-global path. This repo runs several concurrent executor jobs per host (each in its
  # own worktree, each ending in `mix precommit` -> `mix test`); two overlapping runs sharing
  # one fixed tmp path would have run B's setup_all/on_exit rm_rf delete the tree run A is
  # mid-publish from, raising File.Error for reasons unrelated to either branch.
  setup_all do
    src =
      Path.join(
        System.tmp_dir!(),
        "relay_publish_config_test_src_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    for rel <- ~w(bin relay.md .claude/agents .claude/commands .claude/skills) do
      dest = Path.join(src, rel)
      dest |> Path.dirname() |> File.mkdir_p!()
      File.cp_r!(Path.join(File.cwd!(), rel), dest)
    end

    on_exit(fn -> File.rm_rf!(src) end)

    # Guard the invariant the scratch `src` above exists to protect: this repo's own TRACKED
    # `.relay/published.json` must never be touched by running this suite. Snapshot it now and
    # byte-diff it after every test in this module has run (not a value compare — bin/relay's
    # EXECUTOR_VERSION and the tracked marker legitimately disagree mid-branch, see the
    # `--check`/`--check --warn` split below, so a same-content rewrite must still trip this).
    tracked_marker = PublishMarker.path(File.cwd!())
    before_suite = File.read(tracked_marker)

    on_exit(fn ->
      after_suite = File.read(tracked_marker)

      if after_suite != before_suite do
        raise "this repo's tracked #{PublishMarker.rel_path()} changed while running " <>
                "#{inspect(__MODULE__)} — some test published straight to File.cwd!() " <>
                "instead of the isolated src"
      end
    end)

    {:ok, src: src}
  end

  setup %{tmp_dir: tmp_dir, src: src} do
    capture_io(fn -> PublishConfig.publish(src, tmp_dir) end)

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

  test "publishing records what it published in the marker", %{src: src} do
    assert PublishMarker.version(PublishMarker.path(src)) ==
             PublishConfig.executor_version(src)
  end

  test "the scaffolded executor.json advertises the auto-update knob", %{tmp_dir: tmp_dir} do
    cfg = Jason.decode!(File.read!(Path.join(tmp_dir, ".relay/executor.json")))

    assert cfg["auto_update"] == true
    assert cfg["auto_update_min_interval"] == 300
  end

  describe "drift/1 and --check" do
    setup %{tmp_dir: tmp_dir} do
      src = Path.join(tmp_dir, "src")
      File.mkdir_p!(Path.join(src, "bin"))
      File.write!(Path.join(src, "bin/relay"), "#!/usr/bin/env python3\nEXECUTOR_VERSION = 42\n")
      {:ok, src: src}
    end

    test "drifts when nothing has been published", %{src: src} do
      assert PublishConfig.drift(src) == {:drift, 42, nil}
    end

    test "drifts when bin/relay is ahead of the marker", %{src: src} do
      PublishMarker.write!(41, PublishMarker.path(src))

      assert PublishConfig.drift(src) == {:drift, 42, 41}
    end

    test "is clean when the marker matches bin/relay", %{src: src} do
      PublishMarker.write!(42, PublishMarker.path(src))

      assert PublishConfig.drift(src) == {:ok, 42}
    end

    test "--check fails naming both versions and the fix", %{src: src} do
      PublishMarker.write!(41, PublishMarker.path(src))

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn -> PublishConfig.check(src, false) end)
        end

      assert error.message =~ "42"
      assert error.message =~ "41"
      assert error.message =~ "mix relay.publish_config"
    end

    test "run/1 with --check and a path argument checks that path, not the cwd", %{src: src} do
      # `src` is drifted (nothing published); this repo's own cwd is not. If `--check`'s path
      # argument were silently discarded, run/1 would fall back to checking cwd and never raise.
      assert_raise Mix.Error, fn ->
        capture_io(fn -> PublishConfig.run(["--check", src]) end)
      end
    end

    test "--check --warn warns loudly and never fails", %{src: src} do
      PublishMarker.write!(41, PublishMarker.path(src))

      out = capture_io(fn -> assert PublishConfig.check(src, true) == :ok end)

      assert out =~ "publish drift"
      assert out =~ "42"
    end

    test "--check is silent about drift when there is none", %{src: src} do
      PublishMarker.write!(42, PublishMarker.path(src))

      out = capture_io(fn -> assert PublishConfig.check(src, false) == :ok end)

      refute out =~ "drift"
      assert out =~ "42"
    end
  end
end
