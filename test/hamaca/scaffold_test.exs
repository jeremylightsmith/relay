defmodule Hamaca.ScaffoldTest do
  @moduledoc """
  RE304, RE478, RE482. Two halves: `build!/2` against a throwaway source tree (never this
  repo's, so a test can mutate a "skill" freely), and the read side against the scaffold
  `mix test` actually built — which is the thing `/api/scaffold` serves.

  RE482 retired the legacy layout and the compatibility-window shim and aliases: one layout,
  `hamaca`, is built and served; `"legacy"` survives only as `retired_layout/0`, the value the
  controller answers 410 to.
  """
  use ExUnit.Case, async: true

  alias Hamaca.Scaffold

  @moduletag :tmp_dir

  @hamaca_items [
    ".claude/skills/hamaca-doctor/SKILL.md",
    ".claude/skills/hamaca-onboard/SKILL.md",
    ".claude/skills/hamaca-update/SKILL.md",
    "hamaca",
    "hamaca.md"
  ]

  @runner ~s(#!/usr/bin/env python3\nRUNNER_VERSION = 94\nBOARD_URL = ""\n)
  @guide "Run ./hamaca card, see .hamaca/runner.json, hamaca.md, $HAMACA_NODE_SCRATCH, /hamaca-doctor\n"

  setup %{tmp_dir: tmp_dir} do
    src = Path.join(tmp_dir, "src")

    for rel <- @hamaca_items do
      path = Path.join(src, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "contents of #{rel}\n")
    end

    File.write!(Path.join(src, "hamaca"), @runner)
    File.write!(Path.join(src, "hamaca.md"), @guide)

    %{src: src, dest: Path.join(tmp_dir, "out")}
  end

  defp paths(manifest), do: Enum.map(manifest["items"], & &1["path"])

  describe "build!/2" do
    # Scenario 6
    test "builds only the hamaca layout, its manifest the five hamaca items", %{src: src, dest: dest} do
      assert %{"hamaca" => hamaca} = built = Scaffold.build!(src, dest)

      assert Map.keys(built) == ["hamaca"]
      assert File.ls!(dest) == ["hamaca"]
      assert paths(hamaca) == @hamaca_items
      assert paths(hamaca) == Scaffold.items("hamaca")

      for item <- hamaca["items"] do
        assert item["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
        assert item["bytes"] > 0
        assert File.exists?(Path.join([dest, "hamaca", item["path"]]))
      end

      assert dest |> Path.join("hamaca/manifest.json") |> File.read!() |> Jason.decode!() == hamaca
      assert File.read!(Path.join(dest, "hamaca/hamaca")) == @runner
    end

    test "the version is derived from content", %{src: src, dest: dest} do
      first = Scaffold.build!(src, dest)
      second = Scaffold.build!(src, dest)

      assert first["hamaca"]["version"] =~ ~r/\A[0-9a-f]{12}\z/
      assert first["hamaca"]["version"] == second["hamaca"]["version"]

      File.write!(Path.join(src, "hamaca.md"), @guide <> "\n")
      refute Scaffold.build!(src, dest)["hamaca"]["version"] == first["hamaca"]["version"]
    end

    test "a stale layout left by an earlier build is not served", %{src: src, dest: dest} do
      File.mkdir_p!(Path.join(dest, "legacy"))
      File.write!(Path.join(dest, "legacy/relay"), "old legacy build\n")
      File.write!(Path.join(dest, "manifest.json"), "{}\n")

      Scaffold.build!(src, dest)

      refute File.exists?(Path.join(dest, "legacy"))
      refute File.exists?(Path.join(dest, "manifest.json"))
    end

    test "a missing source file is a loud failure, not a silently short manifest",
         %{src: src, dest: dest} do
      File.rm!(Path.join(src, ".claude/skills/hamaca-doctor/SKILL.md"))

      assert_raise File.Error, fn -> Scaffold.build!(src, dest) end
    end
  end

  describe "the layout vocabulary" do
    # Scenario 6
    test "one served layout, the retired one, its 410 code, the param and the runner path" do
      assert Scaffold.layouts() == ["hamaca"]
      assert Scaffold.retired_layout() == "legacy"
      assert Scaffold.retired_code() == "runner_renamed"
      assert Scaffold.layout_param() == "layout"
      assert Scaffold.runner_path("hamaca") == "hamaca"
    end

    # Scenario 6
    test "primary_items/1 is the localized hamaca layout" do
      assert Scaffold.primary_items(".claude/skills") == Scaffold.items("hamaca")
      assert Scaffold.primary_items(".claude/skills") == @hamaca_items

      assert Scaffold.primary_items(".agents/skills") == [
               ".agents/skills/hamaca-doctor/SKILL.md",
               ".agents/skills/hamaca-onboard/SKILL.md",
               ".agents/skills/hamaca-update/SKILL.md",
               "hamaca",
               "hamaca.md"
             ]
    end

    test "local_items/2 moves every skill path to another skill dir, keeping order" do
      assert Scaffold.local_items("hamaca", ".agents/skills") == Scaffold.primary_items(".agents/skills")
      assert Scaffold.local_items("hamaca", Scaffold.skill_dir()) == Scaffold.items("hamaca")
    end

    test "the compatibility-window API is gone" do
      Code.ensure_loaded!(Scaffold)
      refute function_exported?(Scaffold, :default_layout, 0)
      refute function_exported?(Scaffold, :alias_items, 0)
      refute function_exported?(Scaffold, :to_legacy_names, 1)
    end

    test "items/1 is sorted, and sources/0 names every repo source" do
      assert Scaffold.items("hamaca") == Enum.sort(Scaffold.items("hamaca"))
      assert Scaffold.sources() == @hamaca_items
    end

    test "skill_dir/0 is .claude/skills and every skill item lives under it" do
      assert Scaffold.skill_dir() == ".claude/skills"

      for path <- Scaffold.items("hamaca"), String.ends_with?(path, "SKILL.md") do
        assert String.starts_with?(path, ".claude/skills/")
      end
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
    test "the manifest names the items the module declares, and defaults to hamaca" do
      assert {:ok, manifest} = Scaffold.manifest(layout: "hamaca")
      assert paths(manifest) == Scaffold.items("hamaca")
      assert manifest["version"] =~ ~r/\A[0-9a-f]{12}\z/

      assert Scaffold.manifest() == {:ok, manifest}
    end

    test "the retired layout is neither built nor served" do
      assert Scaffold.manifest(layout: "legacy") == :error
      assert Scaffold.fetch("relay", layout: "legacy") == :error
      refute File.exists?(Path.join(Scaffold.root(), "legacy"))
    end

    test "fetch/2 defaults to the hamaca layout and bakes only the runner, and only that line" do
      {:ok, placeholder} = Scaffold.fetch("hamaca")
      assert {:ok, placeholder} == Scaffold.fetch("hamaca", layout: "hamaca")
      assert placeholder =~ ~r/^BOARD_URL = ""$/m

      assert {:ok, baked} = Scaffold.fetch("hamaca", board_url: "https://relay.test")
      assert baked =~ ~r/^BOARD_URL = "https:\/\/relay.test"$/m
      assert Scaffold.bake_board_url(baked, "") == placeholder

      {:ok, guide} = Scaffold.fetch("hamaca.md")
      assert Scaffold.fetch("hamaca.md", board_url: "https://relay.test") == {:ok, guide}
    end

    test "fetch/2 and manifest/1 refuse anything outside the layout, including traversal" do
      assert Scaffold.fetch("../mix.exs") == :error
      assert Scaffold.fetch("mix.exs") == :error
      assert Scaffold.fetch("hamaca/../../mix.exs") == :error
      assert Scaffold.fetch("relay") == :error
      assert Scaffold.fetch("relay.md") == :error
      assert Scaffold.fetch("hamaca", layout: "bogus") == :error
      assert Scaffold.manifest(layout: "bogus") == :error
    end

    test "runner_version/0 is what the served runner declares" do
      {:ok, hamaca} = Scaffold.fetch("hamaca")

      assert is_integer(Scaffold.runner_version())
      assert Scaffold.runner_version() == Scaffold.parse_runner_version(hamaca)
    end

    test "parse_runner_version/1 is nil for anything that declares nothing" do
      assert Scaffold.parse_runner_version("#!/usr/bin/env python3\n") == nil
      assert Scaffold.parse_runner_version("RUNNER_VERSION = 9\n") == 9
    end

    test "the CLI is served from the project root (RE319)" do
      refute "bin/hamaca" in Scaffold.items("hamaca")
    end
  end
end
