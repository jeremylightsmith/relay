defmodule Schemas.HarnessUsageTest do
  @moduledoc """
  RE436 — a harness's board-stored **usage rule**: its changeset, its wire shape, and the pure
  path/condition evaluator (`Schemas.HarnessUsage.Rule`) the runner mirrors in Python.
  """
  use ExUnit.Case, async: true

  alias Schemas.HarnessUsage
  alias Schemas.HarnessUsage.Rule

  defp seed_wire(key) do
    %{usage: usage} = Enum.find(Hamaca.Agents.seed_harnesses(), &(&1.key == key))
    HarnessUsage.wire(usage)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  defp percent_rule do
    HarnessUsage.wire(%HarnessUsage{
      source: "output",
      match: ".t == 1",
      used_unit: "percent",
      resets_unit: "seconds_from_now",
      windows: [%HarnessUsage.Window{label: "d", used_path: ".u", resets_path: ".r", pause_at: 50}]
    })
  end

  @models ["opus", "haiku"]

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "source" => "output",
        "match" => ~s(.type == "x"),
        "used_unit" => "fraction",
        "resets_unit" => "unix",
        "windows" => [%{"label" => "5h", "used_path" => ".a.u", "resets_path" => ".a.r", "pause_at" => 90}],
        "recheck" => %{"model" => "haiku", "interval_min" => 15}
      },
      overrides
    )
  end

  defp change(attrs), do: HarnessUsage.changeset(%HarnessUsage{}, attrs, @models)

  describe "Rule.read/2" do
    # Scenario 1
    test "follows keys and array indexes" do
      assert Rule.read(%{"a" => [%{"b" => 7}]}, ".a[0].b") == 7
    end

    test "a missing key, a non-container or an out-of-range index reads nil" do
      assert Rule.read(%{"a" => 1}, ".x.y") == nil
      assert Rule.read("str", ".a") == nil
      assert Rule.read(%{"a" => [1]}, ".a[3]") == nil
    end

    test "an invalid path reads nil" do
      assert Rule.read(%{"a" => 1}, "a") == nil
      assert Rule.read(%{"a" => 1}, nil) == nil
    end
  end

  describe "Rule.parse_path/1" do
    # Scenario 2
    test "refuses anything outside the .a.b[n] subset" do
      for path <- ["a.b", ".a[", ".a[-1]", "", ".a..b", ".a b"] do
        assert Rule.parse_path(path) == :error, inspect(path)
      end

      assert Rule.parse_path(nil) == :error
      assert Rule.parse_path(42) == :error
    end

    test "splits a dot path into its keys" do
      assert Rule.parse_path(".rate_limit_info.unifiedWindows.five_hour.utilization") ==
               {:ok, ["rate_limit_info", "unifiedWindows", "five_hour", "utilization"]}
    end

    test "array indexes become integers" do
      assert Rule.parse_path(".a[0].b[12]") == {:ok, ["a", 0, "b", 12]}
    end
  end

  describe "Rule.holds?/2" do
    # Scenario 3
    test "evaluates == and != with JSON equality, joined by and" do
      event = %{"type" => "x", "n" => 1, "f" => true, "z" => nil}

      for {condition, expected} <- [
            {~s(.type == "x"), true},
            {~s(.type != "x"), false},
            {".n == 1.0", true},
            {".f == 1", false},
            {".f == true", true},
            {".missing == null", true},
            {".z != null", false},
            {~s(.type == "x" and .n == 2), false},
            {~s(.type == "x" and .n == 1), true}
          ] do
        assert Rule.holds?(event, condition) == expected, condition
      end
    end

    test "and inside a string literal is not a separator" do
      assert Rule.holds?(%{"s" => "a and b"}, ~s(.s == "a and b"))
    end
  end

  describe "Rule.parse_condition/1" do
    # Scenario 4
    test "refuses anything outside the <path> ==|!= <literal> [and …] subset" do
      for condition <- [".a = 1", ".a == ", ".a == foo", ".a == 1 or .b == 2"] do
        assert Rule.parse_condition(condition) == :error, inspect(condition)
      end

      refute Rule.holds?(%{}, ".a = 1")
      refute Rule.holds?(%{}, nil)
    end

    test "parses each clause into {path, op, literal}" do
      assert Rule.parse_condition(~s(.type == "x" and .a[1] != null)) ==
               {:ok, [{["type"], :eq, "x"}, {["a", 1], :ne, nil}]}
    end
  end

  describe "Rule.reading/3" do
    # Scenario 5
    test "the claude-code seed reads both windows off an allowed rate_limit_event" do
      line =
        Jason.decode!(
          ~s({"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.42,"resetsAt":1791651000},"seven_day":{"utilization":0.18,"resetsAt":1792000000}}}})
        )

      assert Rule.reading(seed_wire("claude-code"), line, 1_791_600_000) == %{
               windows: [
                 %{label: "5h", used_pct: 42.0, resets_at: 1_791_651_000},
                 %{label: "7d", used_pct: 18.0, resets_at: 1_792_000_000}
               ],
               refused_resets_at: nil
             }
    end

    # Scenario 6
    test "a rejected line pauses until its own resetsAt, else the latest window reset" do
      line =
        Jason.decode!(
          ~s({"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1791700000,"unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":1791651000}}}})
        )

      wire = seed_wire("claude-code")

      assert Rule.reading(wire, line, 0) == %{
               windows: [%{label: "5h", used_pct: 100.0, resets_at: 1_791_651_000}],
               refused_resets_at: 1_791_700_000
             }

      without_reset = update_in(line, ["rate_limit_info"], &Map.delete(&1, "resetsAt"))
      assert Rule.reading(wire, without_reset, 0).refused_resets_at == 1_791_651_000
    end

    # Scenario 7
    test "the codex seed reads the real codex-cli 0.160.0 token_count line" do
      line =
        Jason.decode!(
          ~s({"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":0.0,"window_minutes":300,"resets_at":1791623773},"secondary":{"used_percent":3.0,"window_minutes":10080,"resets_at":1792000000}}}})
        )

      assert Rule.reading(seed_wire("codex"), line, 0) == %{
               windows: [
                 %{label: "5h", used_pct: 0.0, resets_at: 1_791_623_773},
                 %{label: "wk", used_pct: 3.0, resets_at: 1_792_000_000}
               ],
               refused_resets_at: nil
             }
    end

    # Scenario 8
    test "percent and seconds_from_now units convert" do
      assert Rule.reading(percent_rule(), %{"t" => 1, "u" => 12.5, "r" => 600}, 1000) == %{
               windows: [%{label: "d", used_pct: 12.5, resets_at: 1600}],
               refused_resets_at: nil
             }
    end

    test "a window with a non-number, negative or missing value is omitted" do
      for event <- [
            %{"t" => 1, "u" => true, "r" => 600},
            %{"t" => 1, "u" => "12", "r" => 600},
            %{"t" => 1, "u" => -1, "r" => 600},
            %{"t" => 1, "u" => 12.5},
            %{"t" => 1, "u" => 12.5, "r" => -5}
          ] do
        assert Rule.reading(percent_rule(), event, 1000) == %{windows: [], refused_resets_at: nil}, inspect(event)
      end
    end

    # Scenario 9
    test "a line the rule does not match is not a reading" do
      assert Rule.reading(seed_wire("claude-code"), %{"type" => "assistant"}, 0) == nil
    end

    test "a source none rule never reads" do
      none = HarnessUsage.wire(nil)
      assert none["source"] == "none"
      assert Rule.reading(none, %{"type" => "rate_limit_event"}, 0) == nil
      assert Rule.reading(seed_wire("gemini-cli"), %{"anything" => 1}, 0) == nil
    end

    test "garbage in is nil, never a raise" do
      assert Rule.reading(nil, %{}, 0) == nil
      assert Rule.reading(%{"source" => "output", "match" => 5, "windows" => :x}, %{}, 0) == nil

      assert Rule.reading(%{"source" => "output", "match" => ".a == 1", "windows" => [:x, nil]}, %{"a" => 1}, 0) ==
               %{windows: [], refused_resets_at: nil}
    end
  end

  describe "closed sets" do
    test "each vocabulary is the one copy" do
      assert HarnessUsage.sources() == ["output", "command", "none"]
      assert HarnessUsage.used_units() == ["fraction", "percent"]
      assert HarnessUsage.resets_units() == ["unix", "seconds_from_now"]
    end
  end

  describe "wire/1" do
    test "nil is the wire of an empty rule" do
      assert HarnessUsage.wire(nil) == %{
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
    end

    test "nested embeds are string-keyed" do
      wire = seed_wire("claude-code")

      assert hd(wire["windows"]) == %{
               "label" => "5h",
               "used_path" => ".rate_limit_info.unifiedWindows.five_hour.utilization",
               "resets_path" => ".rate_limit_info.unifiedWindows.five_hour.resetsAt",
               "pause_at" => 90
             }

      assert wire["pause_now"] == %{
               "when" => ~s(.rate_limit_info.status == "rejected"),
               "resets_path" => ".rate_limit_info.resetsAt"
             }

      assert wire["recheck"] == %{"model" => "haiku", "interval_min" => 15}
    end
  end

  describe "changeset/3" do
    # Scenario 10
    test "a full output rule is valid" do
      assert change(valid_attrs()).valid?
    end

    test "a match that is not a condition is refused" do
      assert errors_on(change(valid_attrs(%{"match" => ".a = 1"}))).match == [~s(is not a condition like .type == "x")]
    end

    test "a non-none rule needs a match" do
      assert errors_on(change(valid_attrs(%{"match" => ""}))).match == ["can't be blank"]
    end

    test "no windows are refused" do
      assert {"needs at least one window", _} = change(valid_attrs(%{"windows" => []})).errors[:windows]
    end

    test "duplicate window labels are refused, compared trimmed" do
      window = %{"used_path" => ".u", "resets_path" => ".r", "pause_at" => 90}
      windows = [Map.put(window, "label", "5h"), Map.put(window, "label", " 5h ")]

      assert {~s(has duplicate window "5h"), _} = change(valid_attrs(%{"windows" => windows})).errors[:windows]
    end

    test "pause_at must be 1..100" do
      for pause_at <- [0, 101] do
        windows = [%{"label" => "5h", "used_path" => ".u", "resets_path" => ".r", "pause_at" => pause_at}]
        changeset = change(valid_attrs(%{"windows" => windows}))
        refute changeset.valid?
        assert [%{pause_at: [_]}] = errors_on(changeset).windows
      end

      windows = [%{"label" => "5h", "used_path" => ".u", "resets_path" => ".r", "pause_at" => 100}]
      assert change(valid_attrs(%{"windows" => windows})).valid?
    end

    test "window paths must parse" do
      windows = [%{"label" => "5h", "used_path" => "a.b", "resets_path" => ".r[x]", "pause_at" => 90}]

      assert [%{used_path: ["is not a path like .a.b"], resets_path: ["is not a path like .a.b"]}] =
               errors_on(change(valid_attrs(%{"windows" => windows}))).windows
    end

    test "a window needs a label" do
      windows = [%{"label" => "  ", "used_path" => ".u", "resets_path" => ".r", "pause_at" => 90}]
      assert [%{label: ["can't be blank"]}] = errors_on(change(valid_attrs(%{"windows" => windows}))).windows
    end

    test "recheck.model must be one of the harness's models" do
      changeset = change(valid_attrs(%{"recheck" => %{"model" => "gpt", "interval_min" => 15}}))
      assert errors_on(changeset).recheck == %{model: ["is not one of this harness's models"]}
    end

    test "recheck.interval_min must be positive" do
      changeset = change(valid_attrs(%{"recheck" => %{"model" => "haiku", "interval_min" => 0}}))
      assert %{interval_min: [_]} = errors_on(changeset).recheck
    end

    test "a non-none rule needs a recheck" do
      assert errors_on(change(Map.delete(valid_attrs(), "recheck"))).recheck == ["can't be blank"]
    end

    test "units must be in their closed sets" do
      errors = errors_on(change(valid_attrs(%{"used_unit" => "ratio", "resets_unit" => "iso"})))
      assert errors.used_unit == ["is invalid"]
      assert errors.resets_unit == ["is invalid"]
    end

    test "a command rule with a blank command is refused" do
      errors = errors_on(change(valid_attrs(%{"source" => "command", "command" => " ", "interval_min" => 5})))
      assert errors.command == ["can't be blank"]
    end

    test "a command rule needs a positive interval_min" do
      errors = errors_on(change(valid_attrs(%{"source" => "command", "command" => "x", "interval_min" => 0})))
      assert [_] = errors.interval_min
      assert change(valid_attrs(%{"source" => "command", "command" => "x", "interval_min" => 5})).valid?
    end

    test "source none with nothing else is valid" do
      assert change(%{"source" => "none"}).valid?
    end

    test "an unknown source is refused" do
      assert errors_on(change(%{"source" => "bogus"})).source == ["is invalid"]
    end

    test "pause_now with a blank when becomes nil" do
      changeset = change(valid_attrs(%{"pause_now" => %{"when" => "  ", "resets_path" => ".x"}}))
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :pause_now) == nil
    end

    test "pause_now's when must be a condition and its resets_path a path" do
      changeset = change(valid_attrs(%{"pause_now" => %{"when" => ".s = 1", "resets_path" => "r"}}))

      assert errors_on(changeset).pause_now == %{
               when: [~s(is not a condition like .type == "x")],
               resets_path: ["is not a path like .a.b"]
             }
    end

    test "pause_now without a resets_path is valid" do
      assert change(valid_attrs(%{"pause_now" => %{"when" => ~s(.s == "rejected")}})).valid?
    end
  end

  describe "Schemas.Harness" do
    test "a new harness reads source none" do
      assert %Schemas.Harness{}.usage.source == "none"
    end

    test "the harness changeset casts usage against the harness's models" do
      attrs = %{
        "name" => "Pi",
        "command" => "pi {prompt}",
        "models" => "m1, m2",
        "usage" => valid_attrs(%{"recheck" => %{"model" => "m2", "interval_min" => 5}})
      }

      assert Schemas.Harness.changeset(%Schemas.Harness{}, attrs).valid?

      bad = put_in(attrs, ["usage", "recheck", "model"], "haiku")

      assert errors_on(Schemas.Harness.changeset(%Schemas.Harness{}, bad)).usage.recheck == %{
               model: ["is not one of this harness's models"]
             }
    end
  end
end
