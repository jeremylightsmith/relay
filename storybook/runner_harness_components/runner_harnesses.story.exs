defmodule Storybook.RunnerHarnessComponents.RunnerHarnesses do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.RunnerHarnessComponents.runner_harnesses/1
  def render_source, do: :function

  # The Runners page's per-runner HARNESSES section (RE436). Rows are
  # `Hamaca.Runs.runner_harness_rows/4`'s: one bar per window each harness's USAGE setting defines.
  @now ~U[2026-10-11 15:00:00Z]

  defp claude(overrides \\ %{}) do
    Map.merge(
      %{
        key: "claude-code",
        name: "Claude Code",
        installed: true,
        version: "2.1.270",
        signed_in: :yes,
        source: "output",
        command: nil,
        bars: [
          %{label: "5h", used_pct: 42.0, pause_at: 90, over?: false},
          %{label: "7d", used_pct: 18.0, pause_at: 90, over?: false}
        ],
        read_at: DateTime.add(@now, -120, :second),
        paused: nil,
        others: [],
        agents: ["Claude Opus"]
      },
      overrides
    )
  end

  defp codex(overrides \\ %{}) do
    Map.merge(
      %{
        key: "codex",
        name: "Codex",
        installed: true,
        version: "0.46.0",
        signed_in: :yes,
        source: "command",
        command: "codex-usage --json",
        bars: [
          %{label: "5h", used_pct: 31.0, pause_at: 90, over?: false},
          %{label: "wk", used_pct: 12.0, pause_at: 90, over?: false}
        ],
        read_at: DateTime.add(@now, -360, :second),
        paused: nil,
        others: [],
        agents: []
      },
      overrides
    )
  end

  defp gemini do
    %{
      key: "gemini-cli",
      name: "Gemini CLI",
      installed: false,
      version: nil,
      signed_in: :not_installed,
      source: "none",
      command: nil,
      bars: [],
      read_at: nil,
      paused: nil,
      others: [],
      agents: ["Gemini Pro"]
    }
  end

  def variations do
    [
      %Variation{
        id: :healthy,
        attributes: %{id: "runner-healthy", now: @now, rows: [claude(), codex()]}
      },
      %Variation{
        id: :one_paused,
        attributes: %{
          id: "runner-one-paused",
          now: @now,
          rows: [
            claude(),
            codex(%{
              bars: [
                %{label: "5h", used_pct: 93.0, pause_at: 90, over?: true},
                %{label: "wk", used_pct: 31.0, pause_at: 90, over?: false}
              ],
              paused: %{window: "5h", used_pct: 93.0, pause_at: 90, resets_at: ~U[2026-10-11 16:10:00Z], reason: "limit"},
              others: ["Claude Code"]
            })
          ]
        }
      },
      %Variation{
        id: :not_installed,
        attributes: %{id: "runner-not-installed", now: @now, rows: [claude(), gemini()]}
      },
      %Variation{
        id: :not_reported,
        attributes: %{
          id: "runner-not-reported",
          now: @now,
          rows: [claude(), codex(%{read_at: nil, bars: Enum.map(codex().bars, &%{&1 | used_pct: nil})})]
        }
      }
    ]
  end
end
