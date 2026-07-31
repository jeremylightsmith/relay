defmodule Relay.DocsTaxonomyTest do
  @moduledoc """
  ADR 0008 fixes what lives where. These are its teeth: the docs map exists and names every home,
  and the ADR header convention is uniform. A doc convention with no test is a doc convention that
  drifts back within a month.
  """
  use ExUnit.Case, async: true

  defp read(path), do: File.read!(Path.join(File.cwd!(), path))

  describe "docs/README.md — the map (ADR 0008)" do
    test "names all nine documentation homes" do
      map = read("docs/README.md")

      for home <- [
            "relay.md",
            "priv/docs/",
            "docs/architecture/",
            "docs/adr/",
            "docs/glossary.md",
            "docs/vision.md",
            "docs/designs/",
            "docs/runbooks/",
            "AGENTS.md"
          ] do
        assert map =~ home, "docs/README.md should name the `#{home}` home"
      end
    end

    test "states the published-vs-internal split explicitly" do
      map = read("docs/README.md")

      assert map =~ "Published"
      assert map =~ "only `docs/architecture/` and `docs/runbooks/`"
      assert map =~ "0008-documentation-taxonomy.md"
    end

    test "carries the seven-step placement test" do
      map = read("docs/README.md")

      for step <- ["1.", "2.", "3.", "4.", "5.", "6.", "7."] do
        assert map =~ step
      end
    end
  end

  describe "ADR hygiene (ADR 0008 conventions)" do
    test "every ADR uses the `## Status` section form, never the inline `**Status:**` form" do
      offenders =
        "docs/adr/*.md"
        |> Path.wildcard()
        |> Enum.filter(&(File.read!(&1) =~ ~r/^\*\*Status:\*\*/m))

      assert offenders == [], "these ADRs still use the inline status form: #{inspect(offenders)}"
    end

    test "docs/adr/TEMPLATE.md exists and carries the required sections" do
      template = read("docs/adr/TEMPLATE.md")

      for section <- ["## Status", "## Context", "## Decision", "## Consequences"] do
        assert template =~ section
      end

      assert template =~ "immutable"
    end

    test "the ADR index lists 0005 as Proposed and records that 0003 was amended in place" do
      index = read("docs/adr/README.md")

      refute index =~ "| Draft |"
      assert index =~ ~r/0005.*\| Proposed \|/
      assert index =~ "TEMPLATE.md"
      assert index =~ "0003 was amended in place"
    end
  end

  describe "stale-line sweep (ADR 0008 Phase 0)" do
    test "no page still describes shipped work as planned" do
      refute read("docs/architecture/runtime.md") =~ "empty until W9"
      refute read("priv/docs/getting-started.md") =~ "planned as RLY-177"
    end

    test "api.md's stage sample uses a real category value" do
      api = read("priv/docs/api.md")

      refute api =~ ~s("category": "started"),
             ~s(api.md's stage sample must not use the non-existent "started" category)

      assert api =~ ~s("category": "in_progress")
    end
  end
end
