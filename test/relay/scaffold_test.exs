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

    File.write!(Path.join(src, "relay"), "#!/usr/bin/env python3\nRUNNER_VERSION = 77\n")

    %{src: src, dest: Path.join(tmp_dir, "out")}
  end

  describe "build!/2" do
    test "the manifest lists exactly the five Relay-owned items", %{src: src, dest: dest} do
      manifest = Scaffold.build!(src, dest)

      assert length(Scaffold.items()) == 5
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
      File.rm!(Path.join(src, ".claude/skills/relay-doctor/SKILL.md"))

      assert_raise File.Error, fn -> Scaffold.build!(src, dest) end
    end
  end

  describe "items/0" do
    # RE443: /relay-setup is retired — the board's setup wizard hands out an install command.
    test "is exactly the five Relay-owned paths, sorted, with no relay-setup" do
      assert Scaffold.items() == [
               ".claude/skills/relay-doctor/SKILL.md",
               ".claude/skills/relay-onboard/SKILL.md",
               ".claude/skills/relay-update/SKILL.md",
               "relay",
               "relay.md"
             ]

      assert Scaffold.items() == Enum.sort(Scaffold.items())
      refute Enum.any?(Scaffold.items(), &String.contains?(&1, "relay-setup"))
    end
  end

  describe "skill_dir/0 and items/1 (RE457)" do
    # Scenario 1
    test "skill_dir/0 is .claude/skills and every skill item lives under it" do
      assert Scaffold.skill_dir() == ".claude/skills"

      skills = Scaffold.items() -- ["relay", "relay.md"]
      assert length(skills) == 3
      assert Enum.all?(skills, &String.starts_with?(&1, ".claude/skills/relay-"))
    end

    # Scenario 2
    test "items/1 maps the skill items to another skill dir, keeping order" do
      assert Scaffold.items(".agents/skills") == [
               ".agents/skills/relay-doctor/SKILL.md",
               ".agents/skills/relay-onboard/SKILL.md",
               ".agents/skills/relay-update/SKILL.md",
               "relay",
               "relay.md"
             ]
    end

    # Scenario 3
    test "items/1 with the canonical skill dir is items/0" do
      assert Scaffold.items(".claude/skills") == Scaffold.items()
    end
  end

  describe "bake_board_url/2 and board_url_line/1 (RE443)" do
    test "bakes the URL into the BOARD_URL line" do
      assert Scaffold.bake_board_url("x\nBOARD_URL = \"\"\ny\n", "https://relay.test") ==
               "x\nBOARD_URL = \"https://relay.test\"\ny\n"
    end

    test "a source with no BOARD_URL line is returned unchanged" do
      source = "#!/usr/bin/env python3\nRUNNER_VERSION = 9\n"

      assert Scaffold.bake_board_url(source, "https://relay.test") == source
    end

    test "board_url_line/1 is the JSON-quoted assignment" do
      assert Scaffold.board_url_line("http://board.test") == ~s(BOARD_URL = "http://board.test")
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

    test "the manifest names the same five items the module declares" do
      assert {:ok, manifest} = Scaffold.manifest()
      assert Enum.map(manifest["items"], & &1["path"]) == Scaffold.items()
      assert manifest["version"] =~ ~r/\A[0-9a-f]{12}\z/
    end

    test "fetch/1 returns the served bytes for a manifest path" do
      assert {:ok, source} = Scaffold.fetch("relay")
      assert String.starts_with?(source, "#!")
      assert source =~ "RUNNER_VERSION"
    end

    test "fetch/2 with board_url: bakes the URL into the served relay, and only that line" do
      {:ok, placeholder} = Scaffold.fetch("relay")
      assert placeholder =~ ~r/^BOARD_URL = ""$/m

      assert {:ok, baked} = Scaffold.fetch("relay", board_url: "https://relay.test")
      assert baked =~ ~r/^BOARD_URL = "https:\/\/relay.test"$/m
      assert Scaffold.bake_board_url(baked, "") == placeholder
    end

    test "fetch/1 refuses anything outside the manifest, including traversal" do
      assert Scaffold.fetch("mix.exs") == :error
      assert Scaffold.fetch("../../mix.exs") == :error
      assert Scaffold.fetch("relay/../../mix.exs") == :error
    end

    test "runner_version/0 is what the served ./relay declares" do
      {:ok, source} = Scaffold.fetch("relay")

      assert is_integer(Scaffold.runner_version())
      assert Scaffold.runner_version() == Scaffold.parse_runner_version(source)
    end

    test "parse_runner_version/1 is nil for anything that declares nothing" do
      assert Scaffold.parse_runner_version("#!/usr/bin/env python3\n") == nil
      assert Scaffold.parse_runner_version("RUNNER_VERSION = 9\n") == 9
    end

    test "the CLI is served from the project root (RE319)" do
      assert "relay" in Scaffold.items()
      refute "bin/relay" in Scaffold.items()
      assert Scaffold.items() == Enum.sort(Scaffold.items())
    end
  end
end
