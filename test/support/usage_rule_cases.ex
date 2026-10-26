defmodule Hamaca.UsageRuleCases do
  @moduledoc """
  RE436 — the hand-authored cases BOTH usage-rule evaluators must pass: `Schemas.HarnessUsage.Rule`
  (`test/hamaca/usage_rule_cases_test.exs`) and its Python mirror in `./relay`
  (`bin/test_relay.py`'s `UsageRuleContractTest`). The runner contract test copies them into
  `test/fixtures/runner_contract.json` as `usage_rule_cases`, which is where Python reads them, so
  the two evaluators cannot drift without one side going red.

  Everything here is JSON-shaped — string keys, `nil` for `null` — because it round-trips through
  the fixture file.
  """

  alias Schemas.HarnessUsage

  @claude_allowed %{
    "type" => "rate_limit_event",
    "rate_limit_info" => %{
      "status" => "allowed",
      "unifiedWindows" => %{
        "five_hour" => %{"utilization" => 0.42, "resetsAt" => 1_791_651_000},
        "seven_day" => %{"utilization" => 0.18, "resetsAt" => 1_792_000_000}
      }
    }
  }

  @claude_rejected %{
    "type" => "rate_limit_event",
    "rate_limit_info" => %{
      "status" => "rejected",
      "resetsAt" => 1_791_700_000,
      "unifiedWindows" => %{"five_hour" => %{"utilization" => 1.0, "resetsAt" => 1_791_651_000}}
    }
  }

  # codex-cli 0.160.0, verbatim from a rollout file (2026-10).
  @codex_token_count %{
    "type" => "event_msg",
    "payload" => %{
      "type" => "token_count",
      "rate_limits" => %{
        "primary" => %{"used_percent" => 0.0, "window_minutes" => 300, "resets_at" => 1_791_623_773},
        "secondary" => %{"used_percent" => 3.0, "window_minutes" => 10_080, "resets_at" => 1_792_000_000}
      }
    }
  }

  @doc "The shared cases: `paths`, `invalid_paths`, `conditions`, `invalid_conditions`, `readings`."
  @spec cases() :: map()
  def cases do
    %{
      "paths" => paths(),
      "invalid_paths" => [
        "a.b",
        ".a[",
        ".a[-1]",
        "",
        ".a..b",
        ".a b",
        ".",
        "..a",
        ".a.",
        ".a[1",
        ".a]",
        ".a[1.5]",
        ".a[x]",
        ".[0]",
        " .a"
      ],
      "conditions" => conditions(),
      "invalid_conditions" => [
        ".a = 1",
        ".a == ",
        ".a == foo",
        ".a == 1 or .b == 2",
        "",
        ".a",
        "a == 1",
        ".a == 1 and",
        ".a == 1 and and .b == 1",
        ~s(.a == "unterminated),
        ".a == 01",
        ".a === 1",
        ".a == True",
        ".a == 1e400",
        ".a == 1and .b == 1",
        ~s(.a == "x"and .b == 1),
        ~s(.a == "bad \\q escape")
      ],
      "readings" => readings()
    }
  end

  defp paths do
    [
      %{"event" => %{"a" => [%{"b" => 7}]}, "path" => ".a[0].b", "segments" => ["a", 0, "b"], "value" => 7},
      %{"event" => %{"a" => 1}, "path" => ".x.y", "segments" => ["x", "y"], "value" => nil},
      %{"event" => "str", "path" => ".a", "segments" => ["a"], "value" => nil},
      %{"event" => %{"a" => [1]}, "path" => ".a[3]", "segments" => ["a", 3], "value" => nil},
      %{"event" => %{"a" => true}, "path" => ".a.b", "segments" => ["a", "b"], "value" => nil},
      %{"event" => %{"a" => %{"0" => 1}}, "path" => ".a[0]", "segments" => ["a", 0], "value" => nil},
      %{"event" => %{"a" => [5]}, "path" => ".a.b", "segments" => ["a", "b"], "value" => nil},
      %{
        "event" => %{"a" => %{"b" => [[1, 2], [3, %{"c" => "d"}]]}},
        "path" => ".a.b[1][1].c",
        "segments" => ["a", "b", 1, 1, "c"],
        "value" => "d"
      },
      %{"event" => %{"a" => %{"b" => nil}}, "path" => ".a.b", "segments" => ["a", "b"], "value" => nil},
      %{"event" => %{"a" => %{"b" => false}}, "path" => ".a.b", "segments" => ["a", "b"], "value" => false},
      %{
        "event" => @claude_allowed,
        "path" => ".rate_limit_info.unifiedWindows.five_hour.utilization",
        "segments" => ["rate_limit_info", "unifiedWindows", "five_hour", "utilization"],
        "value" => 0.42
      }
    ]
  end

  defp conditions do
    event = %{"type" => "x", "n" => 1, "f" => true, "z" => nil}

    Enum.map(
      [
        {event, ~s(.type == "x"), true},
        {event, ~s(.type != "x"), false},
        {event, ".n == 1.0", true},
        {event, ".n == 1e0", true},
        {event, ".n == -1", false},
        {event, ".f == 1", false},
        {event, ".f == true", true},
        {event, ".f != false", true},
        {event, ".missing == null", true},
        {event, ".z != null", false},
        {event, ".z == false", false},
        {event, ~s(.n == "1"), false},
        {event, ~s(.type == "x" and .n == 2), false},
        {event, ~s(.type == "x" and .n == 1), true},
        {event, ~s(.type == "x"   and   .n == 1  ), true},
        {event, ~s(.type=="x"), true},
        {%{"s" => "a and b"}, ~s(.s == "a and b"), true},
        {%{"s" => ~s(say "hi")}, ~s(.s == "say \\"hi\\""), true},
        {%{"a" => [1, %{"b" => "c"}]}, ~s(.a[1].b == "c"), true},
        {%{"o" => %{"k" => 1}}, ".o == 1", false},
        {%{"o" => %{"k" => 1}}, ".o != null", true},
        {"not an object", ".a == null", true},
        {@claude_rejected, ~s(.rate_limit_info.status == "rejected"), true},
        {@codex_token_count, ~s(.payload.type == "token_count"), true}
      ],
      fn {event, condition, holds} -> %{"event" => event, "condition" => condition, "holds" => holds} end
    )
  end

  defp readings do
    claude = seed_wire("claude-code")
    codex = seed_wire("codex")

    percent =
      HarnessUsage.wire(%HarnessUsage{
        source: "output",
        match: ".t == 1",
        used_unit: "percent",
        resets_unit: "seconds_from_now",
        windows: [%HarnessUsage.Window{label: "d", used_path: ".u", resets_path: ".r", pause_at: 50}]
      })

    without_reset = update_in(@claude_rejected, ["rate_limit_info"], &Map.delete(&1, "resetsAt"))

    [
      reading("claude-code allowed rate_limit_event (AC2)", claude, @claude_allowed, 1_791_600_000, %{
        "windows" => [
          %{"label" => "5h", "used_pct" => 42.0, "resets_at" => 1_791_651_000},
          %{"label" => "7d", "used_pct" => 18.0, "resets_at" => 1_792_000_000}
        ],
        "refused_resets_at" => nil
      }),
      reading("claude-code rejected line pauses until its resetsAt", claude, @claude_rejected, 0, %{
        "windows" => [%{"label" => "5h", "used_pct" => 100.0, "resets_at" => 1_791_651_000}],
        "refused_resets_at" => 1_791_700_000
      }),
      reading("claude-code rejected line without resetsAt pauses until the latest window", claude, without_reset, 0, %{
        "windows" => [%{"label" => "5h", "used_pct" => 100.0, "resets_at" => 1_791_651_000}],
        "refused_resets_at" => 1_791_651_000
      }),
      reading(
        "pause_now alone (match fails) reads no windows",
        claude,
        %{"rate_limit_info" => %{"status" => "rejected", "resetsAt" => 5}},
        0,
        %{"windows" => [], "refused_resets_at" => 5}
      ),
      reading(
        "pause_now alone with no reset anywhere",
        claude,
        %{"rate_limit_info" => %{"status" => "rejected"}},
        0,
        %{"windows" => [], "refused_resets_at" => nil}
      ),
      reading(
        "an integer fraction and a fractional unix reset",
        claude,
        %{
          "type" => "rate_limit_event",
          "rate_limit_info" => %{
            "unifiedWindows" => %{"seven_day" => %{"utilization" => 1, "resetsAt" => 1_792_000_000.7}}
          }
        },
        0,
        %{
          "windows" => [%{"label" => "7d", "used_pct" => 100.0, "resets_at" => 1_792_000_000}],
          "refused_resets_at" => nil
        }
      ),
      reading("the real codex-cli 0.160.0 token_count line", codex, @codex_token_count, 0, %{
        "windows" => [
          %{"label" => "5h", "used_pct" => 0.0, "resets_at" => 1_791_623_773},
          %{"label" => "wk", "used_pct" => 3.0, "resets_at" => 1_792_000_000}
        ],
        "refused_resets_at" => nil
      }),
      reading("percent and seconds_from_now", percent, %{"t" => 1, "u" => 12.5, "r" => 600}, 1000, %{
        "windows" => [%{"label" => "d", "used_pct" => 12.5, "resets_at" => 1600}],
        "refused_resets_at" => nil
      }),
      reading("seconds_from_now of zero", percent, %{"t" => 1, "u" => 0, "r" => 0}, 1000, %{
        "windows" => [%{"label" => "d", "used_pct" => 0.0, "resets_at" => 1000}],
        "refused_resets_at" => nil
      }),
      empty_window("a boolean used is not a number", percent, %{"t" => 1, "u" => true, "r" => 600}),
      empty_window("a string used is not a number", percent, %{"t" => 1, "u" => "12", "r" => 600}),
      empty_window("a negative used", percent, %{"t" => 1, "u" => -1, "r" => 600}),
      empty_window("a missing reset", percent, %{"t" => 1, "u" => 12.5}),
      empty_window("a negative seconds_from_now", percent, %{"t" => 1, "u" => 12.5, "r" => -5}),
      empty_window("a boolean reset is not a number", percent, %{"t" => 1, "u" => 12.5, "r" => true}),
      reading(
        "a zero unix reset is invalid",
        claude,
        %{
          "type" => "rate_limit_event",
          "rate_limit_info" => %{"unifiedWindows" => %{"five_hour" => %{"utilization" => 0.5, "resetsAt" => 0}}}
        },
        0,
        %{"windows" => [], "refused_resets_at" => nil}
      ),
      reading("a line the rule does not match", claude, %{"type" => "assistant"}, 0, nil),
      reading("a match on true is not a match on 1", percent, %{"t" => true, "u" => 1, "r" => 1}, 0, nil),
      reading("source none never reads", HarnessUsage.wire(nil), @claude_allowed, 0, nil),
      reading("the gemini-cli seed never reads", seed_wire("gemini-cli"), @claude_allowed, 0, nil)
    ]
  end

  defp empty_window(name, usage, event),
    do: reading(name, usage, event, 1000, %{"windows" => [], "refused_resets_at" => nil})

  defp reading(name, usage, event, now, expect) do
    %{"name" => name, "usage" => usage, "event" => event, "now" => now, "expect" => expect}
  end

  defp seed_wire(key) do
    %{usage: usage} = Enum.find(Hamaca.Agents.seed_harnesses(), &(&1.key == key))
    HarnessUsage.wire(usage)
  end
end
