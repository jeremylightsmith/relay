defmodule Relay.DocsTaxonomyTest do
  @moduledoc """
  ADR 0008 fixes what lives where. These are its teeth: the docs map exists and names every home,
  and the ADR header convention is uniform. A doc convention with no test is a doc convention that
  drifts back within a month.
  """
  use ExUnit.Case, async: true

  defp read(path), do: File.read!(Path.join(File.cwd!(), path))

  # Only numbered files are ADRs — TEMPLATE.md and README.md live alongside them.
  defp adr_paths, do: Path.wildcard(Path.join(File.cwd!(), "docs/adr/[0-9][0-9][0-9][0-9]-*.md"))

  # The first non-blank line after `## Status` (some ADRs leave a blank line, some don't).
  defp status_line(contents) do
    contents
    |> String.split("\n")
    |> Enum.drop_while(&(String.trim(&1) != "## Status"))
    |> Enum.drop(1)
    |> Enum.find(&(String.trim(&1) != ""))
    |> case do
      nil -> nil
      line -> String.trim(line)
    end
  end

  defp well_formed_status?(nil), do: false

  defp well_formed_status?(line) do
    line =~ ~r/^(Proposed|Accepted) \(\d{4}-\d{2}-\d{2}\)$/ or
      line =~ ~r/^Superseded by \d{4} \(\d{4}-\d{2}-\d{2}\)$/
  end

  # Index rows keyed by link target: `| [NNNN](file.md) | Title | Status |` → %{"file.md" => "Status"}.
  defp index_status_cells(index) do
    for line <- String.split(index, "\n"),
        [_, file] <- [Regex.run(~r/^\|\s*\[\d{4}\]\(([^)]+\.md)\)\s*\|/, line)],
        into: %{} do
      cell = line |> String.trim() |> String.trim_trailing("|") |> String.split("|") |> List.last()
      {file, String.trim(cell)}
    end
  end

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

    test "the ADR index records the template and the 0003 exception" do
      index = read("docs/adr/README.md")

      refute index =~ "| Draft |"
      assert index =~ "TEMPLATE.md"
      assert index =~ "0003 was amended in place"
    end

    test "every ADR's status line is well-formed" do
      offenders =
        for path <- adr_paths(),
            line = status_line(File.read!(path)),
            not well_formed_status?(line) do
          {Path.basename(path), line}
        end

      assert offenders == [],
             "these ADRs have a malformed status line (want `Proposed|Accepted (YYYY-MM-DD)` " <>
               "or `Superseded by NNNN (YYYY-MM-DD)`): #{inspect(offenders)}"
    end

    test "the ADR index Status cell mirrors each file's status line exactly" do
      rows = index_status_cells(read("docs/adr/README.md"))

      offenders =
        for path <- adr_paths(),
            file = Path.basename(path),
            expected = status_line(File.read!(path)),
            not Map.has_key?(rows, file) or rows[file] != expected do
          case Map.fetch(rows, file) do
            {:ok, cell} -> "ADR #{file}: index says #{inspect(cell)}, file says #{inspect(expected)}"
            :error -> "ADR #{file}: no row in docs/adr/README.md"
          end
        end

      assert offenders == [], "the ADR index disagrees with the files: #{inspect(offenders)}"
    end

    test "the template and the index document the Implementation line and As built section" do
      for path <- ["docs/adr/TEMPLATE.md", "docs/adr/README.md"] do
        doc = read(path)
        assert doc =~ "**Implementation:**", "#{path} should document the `**Implementation:**` line"
        assert doc =~ "## As built", "#{path} should document the `## As built` section"
      end
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

  describe "the state machine has one home (ADR 0008 Phase 1/2)" do
    test "ADR 0007 no longer hand-draws the card-status or run-status machines" do
      adr = read("docs/adr/0007-card-lifecycle-and-failure-states.md")

      refute adr =~ "stateDiagram-v2",
             "ADR 0007 must link to state.md, not re-draw the state machines"

      refute adr =~ "parked_reason",
             "the parked_reason table belongs to state.md alone"

      assert adr =~ "../architecture/state.md"
    end

    test "ADR 0007 keeps the decision and the known gaps but not the failure grid" do
      adr = read("docs/adr/0007-card-lifecycle-and-failure-states.md")

      assert adr =~ "## Decision"
      assert adr =~ "### The happy path"
      assert adr =~ "### Where the machines meet"
      assert adr =~ "## Known gaps"
      assert adr =~ "../architecture/failures.md"

      refute adr =~ "| A1 |", "the failure grid moved to docs/architecture/failures.md"
      refute adr =~ "| F2 |"
    end

    test "failures.md carries the whole A1-F2 grid" do
      failures = read("docs/architecture/failures.md")

      assert String.starts_with?(failures, "# Failure modes")

      for id <- ~w(A1 A2 A3 A4 A5 A6 A7 A8 A9 A10 B1 C1 C2 C3 C4 C5 D1 D2 D3 D4 D5 E1 E2 E3 F1 F2) do
        assert failures =~ "| #{id} |", "failures.md is missing row #{id}"
      end

      # RE253 — the A1/A4 split is only useful if the page names the function that decides it.
      assert failures =~ "Relay.Runs.park_kind/1"

      assert failures =~ "*Sources of truth:"
    end

    test "domain.md's Runs entry is trimmed to peer size and links out" do
      lines = "docs/architecture/domain.md" |> read() |> String.split("\n")
      start = Enum.find_index(lines, &String.starts_with?(&1, "- **Runs**"))
      assert start, "domain.md should still have a `- **Runs**` context bullet"

      body =
        lines
        |> Enum.drop(start + 1)
        |> Enum.take_while(&(not String.starts_with?(&1, "- **")))

      assert length(body) + 1 < 20,
             "the Runs bullet is #{length(body) + 1} lines — trim it to peer size and link out"

      entry = Enum.join([Enum.at(lines, start) | body], "\n")
      assert entry =~ "state.md"
      assert entry =~ "runner.md"
    end

    test "domain.md no longer describes shipped ADR 0006 cards as planned" do
      domain = read("docs/architecture/domain.md")

      refute domain =~ "Planned by [ADR 0006]"
      refute domain =~ "for card 04's pull transport"
    end
  end
end
