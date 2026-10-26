defmodule Hamaca.Runs.RunnerHarnessRowsTest do
  @moduledoc "RE436 — `Hamaca.Runs.runner_harness_rows/4`: a runner's reported harnesses joined with the board's."
  use ExUnit.Case, async: true

  alias Hamaca.Runs
  alias Schemas.Agent
  alias Schemas.Harness
  alias Schemas.HarnessUsage
  alias Schemas.HarnessUsage.Window

  @now ~U[2026-10-11 12:00:00Z]

  defp window(label), do: %Window{label: label, pause_at: 90}

  defp harnesses do
    [
      %Harness{
        id: 1,
        key: "claude-code",
        name: "Claude Code",
        usage: %HarnessUsage{source: "output", windows: [window("5h"), window("7d")]}
      },
      %Harness{
        id: 2,
        key: "codex",
        name: "Codex",
        usage: %HarnessUsage{source: "command", command: "codex usage", windows: [window("5h"), window("wk")]}
      },
      %Harness{id: 3, key: "gemini-cli", name: "Gemini CLI", usage: %HarnessUsage{source: "none"}}
    ]
  end

  defp agents do
    [
      %Agent{name: "Gemini Pro", harness_id: 3},
      %Agent{name: "Claude Opus", harness_id: 1}
    ]
  end

  defp reading(source, windows, paused \\ nil) do
    %{
      "source" => source,
      "read_at" => DateTime.to_unix(DateTime.add(@now, -120, :second)),
      "windows" => for({label, pct} <- windows, do: %{"label" => label, "used_pct" => pct, "resets_at" => 1}),
      "paused" => paused
    }
  end

  defp entry(key, opts) do
    %{
      "key" => key,
      "installed" => Keyword.get(opts, :installed, true),
      "version" => opts[:version],
      "signed_in" => Keyword.get(opts, :signed_in, true),
      "usage" => opts[:usage]
    }
  end

  defp codex_paused(resets_at) do
    %{
      "label" => "5h",
      "used_pct" => 93.0,
      "pause_at" => 90,
      "resets_at" => DateTime.to_unix(resets_at),
      "reason" => "limit"
    }
  end

  defp entries(codex_resets_at \\ DateTime.add(@now, 3600, :second)) do
    [
      entry("claude-code", usage: reading("output", [{"5h", 42.0}, {"7d", 18.0}])),
      entry("codex", usage: reading("command", [{"5h", 93.0}, {"wk", 31.0}], codex_paused(codex_resets_at))),
      entry("gemini-cli", installed: false, signed_in: nil)
    ]
  end

  defp row(rows, key), do: Enum.find(rows, &(&1.key == key))

  describe "scenario 1: the board's harnesses joined with the runner's report" do
    setup do
      %{rows: Runs.runner_harness_rows(entries(), harnesses(), agents(), @now)}
    end

    test "rows come in board harness order", %{rows: rows} do
      assert Enum.map(rows, & &1.key) == ["claude-code", "codex", "gemini-cli"]
    end

    test "a row draws one bar per configured window, with its reading", %{rows: rows} do
      assert row(rows, "claude-code").bars == [
               %{label: "5h", used_pct: 42.0, pause_at: 90, over?: false},
               %{label: "7d", used_pct: 18.0, pause_at: 90, over?: false}
             ]
    end

    test "a paused harness names its window, its over bar and the harnesses still claiming", %{rows: rows} do
      codex = row(rows, "codex")

      assert codex.paused.window == "5h"
      assert codex.paused.resets_at == DateTime.add(@now, 3600, :second)
      assert %{label: "5h", over?: true} = Enum.find(codex.bars, &(&1.label == "5h"))
      assert codex.others == ["Claude Code"]
    end

    test "a not-installed harness is :not_installed and names its board agents", %{rows: rows} do
      gemini = row(rows, "gemini-cli")

      assert gemini.signed_in == :not_installed
      assert gemini.installed == false
      assert gemini.agents == ["Gemini Pro"]
    end

    test "a row carries the board definition's source and command and the reading's age", %{rows: rows} do
      codex = row(rows, "codex")

      assert codex.name == "Codex"
      assert codex.source == "command"
      assert codex.command == "codex usage"
      assert codex.read_at == DateTime.add(@now, -120, :second)
      assert row(rows, "gemini-cli").source == "none"
      assert row(rows, "claude-code").agents == ["Claude Opus"]
    end
  end

  describe "scenario 2: only harnesses both on the board and reported" do
    test "an unreported board harness and an off-board report produce no row" do
      reported = [entry("pi", []), entry("claude-code", [])]

      rows = Runs.runner_harness_rows(reported, harnesses(), agents(), @now)

      assert Enum.map(rows, & &1.key) == ["claude-code"]
    end

    test "signed_in nil reads :na and false reads :no" do
      reported = [entry("claude-code", signed_in: nil), entry("codex", signed_in: false)]

      rows = Runs.runner_harness_rows(reported, harnesses(), agents(), @now)

      assert row(rows, "claude-code").signed_in == :na
      assert row(rows, "codex").signed_in == :no
    end

    test "signed_in true reads :yes" do
      rows = Runs.runner_harness_rows([entry("claude-code", [])], harnesses(), agents(), @now)

      assert row(rows, "claude-code").signed_in == :yes
    end
  end

  describe "scenario 3: a pause past its reset" do
    test "reads as not paused and counts in other rows' others" do
      rows = Runs.runner_harness_rows(entries(DateTime.add(@now, -1, :second)), harnesses(), agents(), @now)

      assert row(rows, "codex").paused == nil
      assert row(rows, "claude-code").others == ["Codex"]
    end
  end

  test "a configured window with no reading has a nil used_pct and is not over" do
    rows = Runs.runner_harness_rows([entry("codex", usage: nil)], harnesses(), agents(), @now)

    assert row(rows, "codex").bars == [
             %{label: "5h", used_pct: nil, pause_at: 90, over?: false},
             %{label: "wk", used_pct: nil, pause_at: 90, over?: false}
           ]

    assert row(rows, "codex").read_at == nil
  end
end
