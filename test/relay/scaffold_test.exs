defmodule Relay.ScaffoldTest do
  @moduledoc """
  RE304. Two halves: `build!/2` against a throwaway source tree (never this repo's, so a test
  can mutate a "skill" freely), and the read side against the scaffold `mix test` actually
  built — which is the thing `/api/scaffold` serves.
  """
  use ExUnit.Case, async: true

  alias Relay.Scaffold

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    src = Path.join(tmp_dir, "src")

    for rel <- Scaffold.items() do
      path = Path.join(src, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "contents of #{rel}\n")
    end

    File.write!(Path.join(src, "bin/relay"), "#!/usr/bin/env python3\nEXECUTOR_VERSION = 77\n")

    %{src: src, dest: Path.join(tmp_dir, "out")}
  end

  describe "build!/2" do
    test "the manifest lists exactly the six Relay-owned items", %{src: src, dest: dest} do
      manifest = Scaffold.build!(src, dest)

      assert length(Scaffold.items()) == 6
      assert Enum.map(manifest["items"], & &1["path"]) == Scaffold.items()

      for item <- manifest["items"] do
        assert item["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
        assert item["bytes"] > 0
        assert File.exists?(Path.join(dest, item["path"]))
      end
    end

    test "the version is derived from content, so the same inputs give the same version",
         %{src: src, dest: dest} do
      first = Scaffold.build!(src, dest)
      second = Scaffold.build!(src, dest)

      assert first["version"] =~ ~r/\A[0-9a-f]{12}\z/
      assert first["version"] == second["version"]
    end

    test "changing one byte of one file changes the version", %{src: src, dest: dest} do
      before = Scaffold.build!(src, dest)["version"]
      doctor = Path.join(src, ".claude/skills/relay-doctor/SKILL.md")
      File.write!(doctor, File.read!(doctor) <> "\n")

      refute Scaffold.build!(src, dest)["version"] == before
    end

    test "a stale item left by an earlier build is not served", %{src: src, dest: dest} do
      File.mkdir_p!(Path.join(dest, "bin"))
      File.write!(Path.join(dest, "bin/leftover"), "old\n")

      Scaffold.build!(src, dest)

      refute File.exists?(Path.join(dest, "bin/leftover"))
    end

    test "a missing source file is a loud failure, not a silently short manifest",
         %{src: src, dest: dest} do
      File.rm!(Path.join(src, ".claude/skills/relay-setup/SKILL.md"))

      assert_raise File.Error, fn -> Scaffold.build!(src, dest) end
    end
  end

  describe "the scaffold this build serves" do
    test "relay.md is served, so a project's Relay guide refreshes with the tooling" do
      # RE304 left relay.md out on the grounds that only never-edited files are Relay-owned.
      # It is a generic guide with no repo-specific content, so leaving it undistributed just
      # meant every project's copy rotted in place — including the node/outcome contract that
      # skills read to work a card correctly.
      assert "relay.md" in Scaffold.items()
      assert {:ok, body} = Scaffold.fetch("relay.md")
      assert body =~ "RELAY_NODE_SCRATCH"
    end

    test "the manifest names the same six items the module declares" do
      assert {:ok, manifest} = Scaffold.manifest()
      assert Enum.map(manifest["items"], & &1["path"]) == Scaffold.items()
      assert manifest["version"] =~ ~r/\A[0-9a-f]{12}\z/
    end

    test "fetch/1 returns the served bytes for a manifest path" do
      assert {:ok, source} = Scaffold.fetch("bin/relay")
      assert String.starts_with?(source, "#!")
      assert source =~ "EXECUTOR_VERSION"
    end

    test "fetch/1 refuses anything outside the manifest, including traversal" do
      assert Scaffold.fetch("mix.exs") == :error
      assert Scaffold.fetch("../../mix.exs") == :error
      assert Scaffold.fetch("bin/relay/../../mix.exs") == :error
    end

    test "executor_version/0 is what the served bin/relay declares" do
      {:ok, source} = Scaffold.fetch("bin/relay")

      assert is_integer(Scaffold.executor_version())
      assert Scaffold.executor_version() == Scaffold.parse_executor_version(source)
    end

    test "parse_executor_version/1 is nil for anything that declares nothing" do
      assert Scaffold.parse_executor_version("#!/usr/bin/env python3\n") == nil
      assert Scaffold.parse_executor_version("EXECUTOR_VERSION = 9\n") == 9
    end
  end
end
