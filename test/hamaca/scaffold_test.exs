defmodule Hamaca.ScaffoldTest do
  @moduledoc """
  RE304, RE478. Two halves: `build!/2` against a throwaway source tree (never this repo's, so a
  test can mutate a "skill" freely), and the read side against the scaffold `mix test` actually
  built — which is the thing `/api/scaffold` serves.

  RE478 builds two layouts from one set of Hamaca-named sources: `legacy` (what every v≤93
  `./relay` gets — a full runner at `relay`, complete `relay.md` and `relay-*` skills generated
  by `to_legacy_names/1`) and `hamaca` (the runner at `hamaca`, the `relay` shim and the thin
  `relay-*` alias skills served as they are).
  """
  use ExUnit.Case, async: true

  alias Hamaca.Scaffold

  @moduletag :tmp_dir

  @legacy_items [
    ".claude/skills/relay-doctor/SKILL.md",
    ".claude/skills/relay-onboard/SKILL.md",
    ".claude/skills/relay-update/SKILL.md",
    "relay",
    "relay.md"
  ]

  @hamaca_items [
    ".claude/skills/hamaca-doctor/SKILL.md",
    ".claude/skills/hamaca-onboard/SKILL.md",
    ".claude/skills/hamaca-update/SKILL.md",
    ".claude/skills/relay-doctor/SKILL.md",
    ".claude/skills/relay-onboard/SKILL.md",
    ".claude/skills/relay-update/SKILL.md",
    "hamaca",
    "hamaca.md",
    "relay"
  ]

  # Every repo source a layout is built from: the hamaca-named files, the shim and the aliases.
  @sources [
    ".claude/skills/hamaca-doctor/SKILL.md",
    ".claude/skills/hamaca-onboard/SKILL.md",
    ".claude/skills/hamaca-update/SKILL.md",
    ".claude/skills/relay-doctor/SKILL.md",
    ".claude/skills/relay-onboard/SKILL.md",
    ".claude/skills/relay-update/SKILL.md",
    "hamaca",
    "hamaca.md",
    "relay"
  ]

  @runner ~s(#!/usr/bin/env python3\nRUNNER_VERSION = 94\nBOARD_URL = ""\n)
  @guide "Run ./hamaca card, see .hamaca/runner.json, hamaca.md, $HAMACA_NODE_SCRATCH, /hamaca-doctor\n"
  @update_skill "---\nname: hamaca-update\ndescription: Refresh ./hamaca\n---\nRun ./hamaca update; it writes .hamaca/scaffold.json.\n"
  @shim "#!/usr/bin/env python3\n# the ./relay shim\n"
  @doctor_alias "---\nname: relay-doctor\ndescription: doctor\n---\nRenamed: use /hamaca-doctor.\n"

  setup %{tmp_dir: tmp_dir} do
    src = Path.join(tmp_dir, "src")

    for rel <- @sources do
      path = Path.join(src, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "contents of #{rel}\n")
    end

    write = fn rel, body -> File.write!(Path.join(src, rel), body) end
    write.("hamaca", @runner)
    write.("hamaca.md", @guide)
    write.(".claude/skills/hamaca-update/SKILL.md", @update_skill)
    write.("relay", @shim)
    write.(".claude/skills/relay-doctor/SKILL.md", @doctor_alias)

    %{src: src, dest: Path.join(tmp_dir, "out")}
  end

  defp paths(manifest), do: Enum.map(manifest["items"], & &1["path"])

  defp built(dest, layout, rel), do: File.read!(Path.join([dest, layout, rel]))

  describe "build!/2" do
    # Scenario 1
    test "builds both layouts, each listing exactly its own items", %{src: src, dest: dest} do
      assert %{"hamaca" => hamaca, "legacy" => legacy} = Scaffold.build!(src, dest)

      assert paths(legacy) == Scaffold.items("legacy")
      assert paths(legacy) == @legacy_items
      assert paths(hamaca) == Scaffold.items("hamaca")
      assert paths(hamaca) == @hamaca_items

      for {layout, manifest} <- [{"hamaca", hamaca}, {"legacy", legacy}], item <- manifest["items"] do
        assert item["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
        assert item["bytes"] > 0
        assert File.exists?(Path.join([dest, layout, item["path"]]))
      end

      for layout <- ["hamaca", "legacy"] do
        assert dest |> Path.join("#{layout}/manifest.json") |> File.read!() |> Jason.decode!() ==
                 Map.fetch!(%{"hamaca" => hamaca, "legacy" => legacy}, layout)
      end
    end

    # Scenario 2
    test "legacy relay and hamaca hamaca are both the full runner, byte for byte",
         %{src: src, dest: dest} do
      Scaffold.build!(src, dest)

      assert built(dest, "legacy", "relay") == @runner
      assert built(dest, "hamaca", "hamaca") == @runner
    end

    # Scenario 3
    test "the legacy guide and skills are generated from the hamaca sources with the old names",
         %{src: src, dest: dest} do
      Scaffold.build!(src, dest)

      assert built(dest, "legacy", "relay.md") ==
               "Run ./relay card, see .relay/runner.json, relay.md, $RELAY_NODE_SCRATCH, /relay-doctor\n"

      update = built(dest, "legacy", ".claude/skills/relay-update/SKILL.md")
      assert update == Scaffold.to_legacy_names(@update_skill)
      assert update =~ "name: relay-update"
    end

    # Scenario 4
    test "the hamaca layout serves the alias skills and the shim as they are", %{src: src, dest: dest} do
      Scaffold.build!(src, dest)

      assert built(dest, "hamaca", ".claude/skills/relay-doctor/SKILL.md") == @doctor_alias
      assert built(dest, "hamaca", "relay") == @shim
    end

    # Scenario 5
    test "each layout's version is derived from content", %{src: src, dest: dest} do
      first = Scaffold.build!(src, dest)
      second = Scaffold.build!(src, dest)

      for layout <- Scaffold.layouts() do
        assert first[layout]["version"] =~ ~r/\A[0-9a-f]{12}\z/
        assert first[layout]["version"] == second[layout]["version"]
      end
    end

    # Scenario 5
    test "a byte changed in hamaca.md moves both layouts' versions", %{src: src, dest: dest} do
      before = Scaffold.build!(src, dest)
      File.write!(Path.join(src, "hamaca.md"), @guide <> "\n")
      later = Scaffold.build!(src, dest)

      refute later["hamaca"]["version"] == before["hamaca"]["version"]
      refute later["legacy"]["version"] == before["legacy"]["version"]
    end

    # Scenario 5
    test "a byte changed only in the shim moves only the hamaca layout's version", %{src: src, dest: dest} do
      before = Scaffold.build!(src, dest)
      File.write!(Path.join(src, "relay"), @shim <> "\n")
      later = Scaffold.build!(src, dest)

      refute later["hamaca"]["version"] == before["hamaca"]["version"]
      assert later["legacy"]["version"] == before["legacy"]["version"]
    end

    test "a stale file left by an earlier (flat) build is not served", %{src: src, dest: dest} do
      File.mkdir_p!(dest)
      File.write!(Path.join(dest, "relay"), "old flat build\n")
      File.write!(Path.join(dest, "manifest.json"), "{}\n")

      Scaffold.build!(src, dest)

      refute File.exists?(Path.join(dest, "relay"))
      refute File.exists?(Path.join(dest, "manifest.json"))
    end

    test "a missing source file is a loud failure, not a silently short manifest",
         %{src: src, dest: dest} do
      File.rm!(Path.join(src, ".claude/skills/hamaca-doctor/SKILL.md"))

      assert_raise File.Error, fn -> Scaffold.build!(src, dest) end
    end
  end

  describe "the layout vocabulary" do
    # Scenario 8
    test "layouts, the default, the param and each layout's runner path" do
      assert Scaffold.layouts() == ["hamaca", "legacy"]
      assert Scaffold.default_layout() == "legacy"
      assert Scaffold.layout_param() == "layout"
      assert Scaffold.runner_path("legacy") == "relay"
      assert Scaffold.runner_path("hamaca") == "hamaca"
    end

    # Scenario 8
    test "alias_items/0 is what the hamaca layout carries only for the compatibility window" do
      assert Scaffold.alias_items() == [
               ".claude/skills/relay-doctor/SKILL.md",
               ".claude/skills/relay-onboard/SKILL.md",
               ".claude/skills/relay-update/SKILL.md",
               "relay"
             ]
    end

    # Scenario 8
    test "local_items/2 moves every skill path to another skill dir, keeping order" do
      assert Scaffold.local_items("hamaca", ".agents/skills") == [
               ".agents/skills/hamaca-doctor/SKILL.md",
               ".agents/skills/hamaca-onboard/SKILL.md",
               ".agents/skills/hamaca-update/SKILL.md",
               ".agents/skills/relay-doctor/SKILL.md",
               ".agents/skills/relay-onboard/SKILL.md",
               ".agents/skills/relay-update/SKILL.md",
               "hamaca",
               "hamaca.md",
               "relay"
             ]

      assert Scaffold.local_items("legacy", Scaffold.skill_dir()) == Scaffold.items("legacy")
    end

    # Scenario 8
    test "primary_items/1 is the hamaca layout without its aliases" do
      assert Scaffold.primary_items(".claude/skills") == [
               ".claude/skills/hamaca-doctor/SKILL.md",
               ".claude/skills/hamaca-onboard/SKILL.md",
               ".claude/skills/hamaca-update/SKILL.md",
               "hamaca",
               "hamaca.md"
             ]
    end

    test "items/1 is sorted for every layout, and sources/0 names every repo source" do
      for layout <- Scaffold.layouts() do
        assert Scaffold.items(layout) == Enum.sort(Scaffold.items(layout))
      end

      assert Enum.sort(Scaffold.sources()) == Enum.sort(@sources)
    end

    test "skill_dir/0 is .claude/skills and every skill item lives under it" do
      assert Scaffold.skill_dir() == ".claude/skills"

      for layout <- Scaffold.layouts(),
          path <- Scaffold.items(layout),
          String.ends_with?(path, "SKILL.md") do
        assert String.starts_with?(path, ".claude/skills/")
      end
    end
  end

  describe "to_legacy_names/1" do
    test "swaps exactly the seven Hamaca tokens and leaves the rest alone" do
      assert Scaffold.to_legacy_names(
               "./hamaca .hamaca/x hamaca.md HAMACA_URL /hamaca-doctor /hamaca-onboard /hamaca-update"
             ) ==
               "./relay .relay/x relay.md RELAY_URL /relay-doctor /relay-onboard /relay-update"

      untouched = "Hamaca {relay} ~/.relay/locks .relay-retained relay start"
      assert Scaffold.to_legacy_names(untouched) == untouched
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
    test "the legacy relay.md is served, generated from hamaca.md with the old names" do
      assert {:ok, body} = Scaffold.fetch("relay.md")
      assert body =~ "RELAY_NODE_SCRATCH"
      assert body == Scaffold.to_legacy_names(File.read!("hamaca.md"))
    end

    test "each layout's manifest names the items the module declares" do
      for layout <- Scaffold.layouts() do
        assert {:ok, manifest} = Scaffold.manifest(layout: layout)
        assert paths(manifest) == Scaffold.items(layout)
        assert manifest["version"] =~ ~r/\A[0-9a-f]{12}\z/
      end

      assert Scaffold.manifest() == Scaffold.manifest(layout: Scaffold.default_layout())
    end

    # Scenario 6
    test "the legacy relay is the full runner with the board URL baked in" do
      assert {:ok, source} = Scaffold.fetch("relay", layout: "legacy", board_url: "https://b.test")
      assert source =~ ~r/^BOARD_URL = "https:\/\/b.test"$/m
      assert is_integer(Scaffold.parse_runner_version(source))
    end

    # Scenario 6
    test "hamaca is served only from the hamaca layout" do
      assert Scaffold.fetch("hamaca", layout: "legacy") == :error
      assert {:ok, _} = Scaffold.fetch("hamaca", layout: "hamaca")
    end

    test "fetch/2 with board_url: bakes only the layout's runner, and only that line" do
      for layout <- Scaffold.layouts() do
        runner = Scaffold.runner_path(layout)
        {:ok, placeholder} = Scaffold.fetch(runner, layout: layout)
        assert placeholder =~ ~r/^BOARD_URL = ""$/m

        assert {:ok, baked} = Scaffold.fetch(runner, layout: layout, board_url: "https://relay.test")
        assert baked =~ ~r/^BOARD_URL = "https:\/\/relay.test"$/m
        assert Scaffold.bake_board_url(baked, "") == placeholder
      end

      {:ok, shim} = Scaffold.fetch("relay", layout: "hamaca")
      assert Scaffold.fetch("relay", layout: "hamaca", board_url: "https://relay.test") == {:ok, shim}
    end

    # Scenario 7
    test "fetch/2 and manifest/1 refuse anything outside the requested layout" do
      assert Scaffold.fetch("../mix.exs", layout: "hamaca") == :error
      assert Scaffold.fetch("relay.md", layout: "hamaca") == :error
      assert Scaffold.manifest(layout: "bogus") == :error
    end

    test "fetch/2 refuses anything outside the manifest, including traversal" do
      assert Scaffold.fetch("mix.exs") == :error
      assert Scaffold.fetch("../../mix.exs") == :error
      assert Scaffold.fetch("relay/../../mix.exs") == :error
      assert Scaffold.fetch("relay", layout: "bogus") == :error
    end

    test "runner_version/0 is what the served runner declares, in both layouts" do
      {:ok, legacy} = Scaffold.fetch("relay")
      {:ok, hamaca} = Scaffold.fetch("hamaca", layout: "hamaca")

      assert legacy == hamaca
      assert is_integer(Scaffold.runner_version())
      assert Scaffold.runner_version() == Scaffold.parse_runner_version(hamaca)
    end

    test "parse_runner_version/1 is nil for anything that declares nothing" do
      assert Scaffold.parse_runner_version("#!/usr/bin/env python3\n") == nil
      assert Scaffold.parse_runner_version("RUNNER_VERSION = 9\n") == 9
    end

    test "the CLI is served from the project root (RE319)" do
      refute "bin/relay" in Scaffold.items("legacy")
      refute "bin/hamaca" in Scaffold.items("hamaca")
    end
  end
end
