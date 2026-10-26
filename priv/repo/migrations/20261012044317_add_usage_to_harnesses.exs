defmodule Hamaca.Repo.Migrations.AddUsageToHarnesses do
  use Ecto.Migration

  # RE436 — every harness gets a board-stored usage rule (`Schemas.HarnessUsage`): how the runner
  # reads that CLI's usage and when it pauses it. The column defaults to `{"source":"none"}`, and
  # each existing board's three seeded harnesses are backfilled with their seed rule.
  #
  # The rules below are a FROZEN copy of the `usage` in `Hamaca.Agents.seed_harnesses/0`, in the
  # wire shape `Schemas.HarnessUsage.wire/1` stores — the one sanctioned exception to the
  # magic-value rule: a migration must replay identically forever, so it never calls app code
  # that may change after it ships.
  @none %{"source" => "none"}

  @rules %{
    "claude-code" => %{
      "source" => "output",
      "match" => ~s(.type == "rate_limit_event"),
      "command" => nil,
      "interval_min" => nil,
      "used_unit" => "fraction",
      "resets_unit" => "unix",
      "windows" => [
        %{
          "label" => "5h",
          "used_path" => ".rate_limit_info.unifiedWindows.five_hour.utilization",
          "resets_path" => ".rate_limit_info.unifiedWindows.five_hour.resetsAt",
          "pause_at" => 90
        },
        %{
          "label" => "7d",
          "used_path" => ".rate_limit_info.unifiedWindows.seven_day.utilization",
          "resets_path" => ".rate_limit_info.unifiedWindows.seven_day.resetsAt",
          "pause_at" => 90
        }
      ],
      "pause_now" => %{
        "when" => ~s(.rate_limit_info.status == "rejected"),
        "resets_path" => ".rate_limit_info.resetsAt"
      },
      "recheck" => %{"model" => "haiku", "interval_min" => 15}
    },
    "codex" => %{
      "source" => "command",
      "match" => ~s(.payload.type == "token_count"),
      "command" =>
        ~S{sh -c 'f=$(ls -t ~/.codex/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -1) && grep -h "\"token_count\"" "$f" | tail -1'},
      "interval_min" => 5,
      "used_unit" => "percent",
      "resets_unit" => "unix",
      "windows" => [
        %{
          "label" => "5h",
          "used_path" => ".payload.rate_limits.primary.used_percent",
          "resets_path" => ".payload.rate_limits.primary.resets_at",
          "pause_at" => 90
        },
        %{
          "label" => "wk",
          "used_path" => ".payload.rate_limits.secondary.used_percent",
          "resets_path" => ".payload.rate_limits.secondary.resets_at",
          "pause_at" => 90
        }
      ],
      "pause_now" => nil,
      "recheck" => %{"model" => "gpt-5.6-luna", "interval_min" => 15}
    },
    "gemini-cli" => %{
      "source" => "none",
      "match" => nil,
      "command" => nil,
      "interval_min" => nil,
      "used_unit" => "fraction",
      "resets_unit" => "unix",
      "windows" => [],
      "pause_now" => nil,
      "recheck" => nil
    }
  }

  def up do
    alter table(:harnesses) do
      add :usage, :map, null: false, default: fragment(~s('{"source":"none"}'::jsonb))
    end

    flush()

    backfill!(repo())
  end

  def down do
    alter table(:harnesses) do
      remove :usage
    end
  end

  @doc """
  Gives every seeded harness still on the column default its frozen seed rule — exactly what `up`
  runs. A harness the board added itself, or one whose rule was already edited, is left alone.
  """
  def backfill!(repo) do
    for {key, rule} <- @rules do
      repo.query!("UPDATE harnesses SET usage = $1 WHERE key = $2 AND usage = $3::jsonb", [
        rule,
        key,
        @none
      ])
    end

    :ok
  end
end
