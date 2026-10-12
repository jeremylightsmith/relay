# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Relay.Repo.Migrations.AddUsageToHarnesses) do
  "priv/repo/migrations/*_add_usage_to_harnesses.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Relay.Migrations.AddUsageToHarnessesTest do
  @moduledoc """
  RE436 — every existing board's seeded harnesses get the frozen seed usage rule; a harness the
  board added itself, and a rule somebody already edited, are left alone.
  """
  use Relay.DataCase, async: true

  alias Relay.Repo
  alias Relay.Repo.Migrations.AddUsageToHarnesses, as: Migration

  @none %{"source" => "none"}

  @edited %{
    "source" => "output",
    "match" => ~s(.type == "x"),
    "command" => nil,
    "interval_min" => nil,
    "used_unit" => "fraction",
    "resets_unit" => "unix",
    "windows" => [%{"label" => "5h", "used_path" => ".u", "resets_path" => ".r", "pause_at" => 50}],
    "pause_now" => nil,
    "recheck" => %{"model" => "opus", "interval_min" => 15}
  }

  defp insert_harness!(board_id, key, usage) do
    Repo.query!(
      """
      INSERT INTO harnesses (board_id, key, name, command, models, usage, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'x {prompt}', $4, $5, now(), now())
      """,
      [board_id, key, key, ["m"], usage]
    )
  end

  defp usage(board_id, key) do
    %{rows: [[usage]]} = Repo.query!("SELECT usage FROM harnesses WHERE board_id = $1 AND key = $2", [board_id, key])
    usage
  end

  # Scenario 13
  test "backfill!/1 gives the seeded harnesses the frozen rules and leaves the rest alone" do
    board = insert(:board)
    for key <- ["claude-code", "codex", "gemini-cli", "pi"], do: insert_harness!(board.id, key, @none)

    other = insert(:board)
    insert_harness!(other.id, "claude-code", @edited)

    assert :ok = Migration.backfill!(Repo)

    assert usage(board.id, "claude-code") == %{
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
           }

    assert usage(board.id, "codex") == %{
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
           }

    assert usage(board.id, "gemini-cli") == %{
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

    assert usage(board.id, "pi") == @none
    assert usage(other.id, "claude-code") == @edited
  end
end
