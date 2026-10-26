defmodule HamacaWeb.RunnerHarnessComponentsTest do
  @moduledoc "RE436 — the Runners page's HARNESSES section (card mockup 02)."
  use HamacaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias HamacaWeb.RunnerHarnessComponents

  @now ~U[2026-10-11 12:00:00Z]

  defp q(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp text(html, selector), do: html |> q(selector) |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()
  defp attr(html, selector, name), do: html |> q(selector) |> LazyHTML.attribute(name) |> List.first()

  defp row(overrides) do
    Map.merge(
      %{
        key: "pi",
        name: "pi",
        installed: true,
        version: "0.9.2",
        signed_in: :na,
        source: "command",
        command: "pi usage --json",
        bars: [%{label: "day", used_pct: 12.0, pause_at: 90, over?: false}],
        read_at: DateTime.add(@now, -180, :second),
        paused: nil,
        others: [],
        agents: []
      },
      Map.new(overrides)
    )
  end

  defp render_rows(rows),
    do: render_component(&RunnerHarnessComponents.runner_harnesses/1, id: "runner-mac", rows: rows, now: @now)

  describe "scenario 7: a command-source row" do
    test "the source line names the command in a mono span and the reading's age" do
      html = render_rows([row([])])

      assert text(html, "#runner-mac-harness-pi-source") == "from pi usage --json · 3m ago"
      assert text(html, "#runner-mac-harness-pi-source .font-mono") == "pi usage --json"
      assert attr(html, "#runner-mac-harness-pi-source .font-mono", "class") =~ "break-all"
      assert attr(html, "#runner-mac-harness-pi-source .font-mono", "title") == "pi usage --json"
    end

    test "the header grid carries the mockup's columns" do
      html = render_rows([row([])])

      assert attr(html, "#runner-mac-harnesses-header", "style") =~
               "grid-template-columns:150px 110px 120px 1fr"

      # Keyed to the table's own width (a container query), not the viewport: in the ~420px
      # runner pane the fixed tracks would crush USAGE, so the row stacks there instead.
      assert attr(html, "#runner-mac-harnesses-header", "class") =~ "hidden @2xl:grid"
      assert attr(html, "#runner-mac-harnesses > div", "class") =~ "@container"
      assert attr(html, "#runner-mac-harness-pi", "class") =~ "@2xl:grid-cols-["
      refute attr(html, "#runner-mac-harness-pi", "class") =~ "md:grid-cols"
      assert text(html, "#runner-mac-harnesses-header") == "HARNESS VERSION SIGNED IN USAGE"
    end
  end

  test "the section label counts the rows" do
    html = render_rows([row([]), row(key: "codex", name: "Codex")])

    assert text(html, "#runner-mac-harnesses > span") == "HARNESSES · 2"
  end

  test "an output-source row reads from its output" do
    html = render_rows([row(source: "output", command: nil)])

    assert text(html, "#runner-mac-harness-pi-source") == "from its output · 3m ago"
  end

  test "a bar's value is rounded and capped at 100 while its label shows the real percent" do
    html = render_rows([row(bars: [%{label: "5h", used_pct: 104.6, pause_at: 90, over?: true}])])

    assert attr(html, ~s(#runner-mac-harness-pi [data-usage-bar="5h"]), "value") == "100"
    assert attr(html, ~s(#runner-mac-harness-pi [data-usage-bar="5h"]), "class") =~ "progress-warning"
    assert text(html, "#runner-mac-harness-pi") =~ "105%"
  end

  test "a version-less row shows —, signed out shows the error ink" do
    html = render_rows([row(version: nil, signed_in: :no)])

    assert text(html, "#runner-mac-harness-pi-version") == "—"
    assert text(html, "#runner-mac-harness-pi-signed-in") == "✗ signed out"

    assert attr(html, "#runner-mac-harness-pi-signed-in", "style") =~
             "color-mix(in oklab, var(--color-error) 65%, var(--color-base-content))"
  end

  test "signed in shows the success ink and n/a is muted" do
    html = render_rows([row(signed_in: :yes), row(key: "pi-2", signed_in: :na)])

    assert text(html, "#runner-mac-harness-pi-signed-in") == "✓ signed in"

    assert attr(html, "#runner-mac-harness-pi-signed-in", "style") =~
             "color-mix(in oklab, var(--color-success) 60%, var(--color-base-content))"

    assert text(html, "#runner-mac-harness-pi-2-signed-in") == "— n/a"
  end

  test "a paused row is tinted amber and its line ends after nodes wait when nothing else claims" do
    paused = %{window: "day", used_pct: 93.0, pause_at: 90, resets_at: ~U[2026-10-11 16:10:00Z], reason: "limit"}
    html = render_rows([row(paused: paused)])

    assert attr(html, "#runner-mac-harness-pi", "style") =~
             "background:color-mix(in oklab, var(--color-warning) 5%, var(--color-base-100))"

    assert text(html, "#runner-mac-harness-pi-paused") ==
             "⏸ Paused — day at 93%, over pi's 90% pause-at; resets 4:10 PM UTC. pi nodes wait."

    assert attr(html, "#runner-mac-harness-pi-paused", "style") =~
             "color-mix(in oklab, var(--color-warning) 50%, var(--color-base-content))"
  end

  test "a rejected pause reads refused a call, and names every harness still claiming" do
    paused = %{window: nil, used_pct: nil, pause_at: nil, resets_at: ~U[2026-10-11 16:10:00Z], reason: "rejected"}
    html = render_rows([row(paused: paused, others: ["Claude Code", "Codex"])])

    assert text(html, "#runner-mac-harness-pi-paused") ==
             "⏸ Paused — pi refused a call; resets 4:10 PM UTC. pi nodes wait; Claude Code and Codex nodes still claim."
  end

  test "a not-installed row is dimmed and names the agents it won't claim for" do
    html =
      render_rows([
        row(
          installed: false,
          signed_in: :not_installed,
          source: "none",
          bars: [],
          read_at: nil,
          agents: ["Gemini Flash", "Gemini Pro"]
        )
      ])

    assert attr(html, "#runner-mac-harness-pi", "style") =~ "opacity:.75"
    assert text(html, "#runner-mac-harness-pi-signed-in") == "✗ not installed"

    assert text(html, "#runner-mac-harness-pi-usage") ==
             "Won't claim nodes that use “Gemini Flash”, “Gemini Pro”. Usage: not reported."
  end

  test "a not-installed row with no agents reads just Usage: not reported" do
    html = render_rows([row(installed: false, signed_in: :not_installed, source: "none", bars: [], agents: [])])

    assert text(html, "#runner-mac-harness-pi-usage") == "Usage: not reported."
  end

  test "a row with no reading yet shows a single — and no bars" do
    html = render_rows([row(read_at: nil, bars: [%{label: "day", used_pct: nil, pause_at: 90, over?: false}])])

    assert text(html, "#runner-mac-harness-pi-usage") == "—"
    assert html |> q("#runner-mac-harness-pi [data-usage-bar]") |> Enum.to_list() == []
  end

  test "only the last row drops its bottom border" do
    html = render_rows([row([]), row(key: "codex")])

    assert attr(html, "#runner-mac-harness-pi", "class") =~ "border-b"
    refute attr(html, "#runner-mac-harness-codex", "class") =~ "border-b"
  end
end
