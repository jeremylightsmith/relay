defmodule Hamaca.RenameRepoStateTest do
  @moduledoc """
  RE478 task 5. This repo runs on the Hamaca names: AGENTS.md points at `hamaca.md` and
  `.hamaca/flows/`, and the process files under `.claude/` say `./hamaca` and
  `$HAMACA_NODE_SCRATCH`. RE482 closed the compatibility window: the `./relay` shim and the
  three `relay-*` alias skills are gone, so no process file carries the old names.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
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

  test "the ./relay shim and the relay-* alias skills are retired (RE482)" do
    refute File.exists?(Path.join(@root, "relay"))

    for name <- ~w(doctor onboard update) do
      refute File.exists?(Path.join(@root, ".claude/skills/relay-#{name}")), "relay-#{name} is still shipped"
    end
  end

  test "no .claude process file names ./relay or $RELAY_NODE_SCRATCH" do
    files =
      ~w(agents commands skills)
      |> Enum.flat_map(&Path.wildcard(Path.join([@root, ".claude", &1, "**", "*.md"])))
      |> Enum.map(&Path.relative_to(&1, @root))

    assert ".claude/agents/plan-implementer.md" in files

    offenders =
      for file <- files, stale <- @stale_in_process_files, read(file) =~ stale, do: {file, stale}

    assert offenders == []
  end
end
