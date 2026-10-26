defmodule Hamaca.RenameRepoStateTest do
  @moduledoc """
  RE478 task 5. This repo runs on the Hamaca names: AGENTS.md points at `hamaca.md` and
  `.hamaca/flows/`, and the process files under `.claude/` say `./hamaca` and
  `$HAMACA_NODE_SCRATCH`. Only the three `relay-*` alias skills (kept for the compatibility
  window, RE482) may still carry the old names.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @alias_skills for name <- ~w(doctor onboard update), do: ".claude/skills/relay-#{name}/SKILL.md"
  @stale_in_process_files ["./relay ", "$RELAY_NODE_SCRATCH"]

  defp read(path), do: File.read!(Path.join(@root, path))

  describe "AGENTS.md" do
    test "points at hamaca.md and .hamaca/flows/" do
      agents = read("AGENTS.md")

      assert agents =~ "hamaca.md"
      assert agents =~ ".hamaca/flows/"
    end

    test "names none of the retired relay paths or skills" do
      agents = read("AGENTS.md")

      for stale <- ["relay.md", ".relay/flows", "/relay-doctor", "/relay-onboard"] do
        refute agents =~ stale, "AGENTS.md still names #{stale}"
      end
    end
  end

  test "no .claude process file but the relay-* alias skills names ./relay or $RELAY_NODE_SCRATCH" do
    files =
      ~w(agents commands skills)
      |> Enum.flat_map(&Path.wildcard(Path.join([@root, ".claude", &1, "**", "*.md"])))
      |> Enum.map(&Path.relative_to(&1, @root))
      |> Kernel.--(@alias_skills)

    assert ".claude/agents/plan-implementer.md" in files

    offenders =
      for file <- files, stale <- @stale_in_process_files, read(file) =~ stale, do: {file, stale}

    assert offenders == []
  end
end
