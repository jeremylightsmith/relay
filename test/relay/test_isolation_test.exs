defmodule Relay.TestIsolationTest do
  @moduledoc """
  Static guard for ADR 0009 (test isolation), amended by RE419.

  Two rules, each defined once, here:

    * **No env writes in tests.** A test varies config by `Process.put/2`-ing a value that
      production reads through `Relay.Config` (ProcessTree), never by writing the app env or the
      OS env — those writes are process-global and leak into every concurrently running test.
      Any line in `test/**/*.exs` or `test/support/**/*.ex` that calls an app/OS env writer is an
      offender, comments included, except in `test/test_helper.exs` (one-time suite setup).

    * **Every serial module says why.** In every non-browser `test/**/*.exs`, a `use …` line that
      opts out of the async pool must be directly preceded (nearest non-blank line above) by a
      `#` comment stating the reason, or sit in a file whose `@moduledoc` explains it.

  The writer names below are assembled from fragments on purpose, so this file never contains
  the contiguous call text that the acceptance grep searches `test/` for.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # The env-write rule: `(Application|System).(put|delete)_env`.
  @env_write ~r/\b(Application|System)\.(put|delete)_env\b/
  # The only file allowed to write env: one-time suite setup.
  @env_write_allowed ["test/test_helper.exs"]

  # The serial-reason rule: a `use X, async: false` line needs a reason.
  @serial_use ~r/^\s*use\s+[\w.]+,\s*async:\s*false\b/

  test "no test writes the app env or the OS env" do
    files = env_scanned_files()
    refute Enum.empty?(files), "env_scanned_files/0 found nothing to scan — did a path move?"
    offenders = Enum.flat_map(files, &env_write_offenders/1)

    assert offenders == [], """
    Tests must not write the app env or the OS env — the write is process-global and leaks into
    every concurrently running test. `Process.put/2` the value instead and read it in production
    through `Relay.Config` (ADR 0009, RE419 amendment).

    #{Enum.map_join(offenders, "\n", fn {rel, line_no, line} -> "  #{rel}:#{line_no}: #{String.trim(line)}" end)}
    """
  end

  test "every non-browser async: false module states why" do
    files = serial_scanned_files()
    refute Enum.empty?(files), "serial_scanned_files/0 found nothing to scan — did a path move?"
    offenders = Enum.flat_map(files, &unreasoned_serial_modules/1)

    assert offenders == [], """
    These modules opt out of the async pool without saying why. Make them `async: true`, or add a
    one-line ADR 0009 reason as a `#` comment directly above the `use` line (or explain it in the
    module's @moduledoc).

    #{Enum.map_join(offenders, "\n", fn {rel, line_no} -> "  #{rel}:#{line_no}" end)}
    """
  end

  # --- scanner ---------------------------------------------------------------

  defp env_scanned_files do
    Path.wildcard(Path.join(@root, "test/**/*.exs")) ++
      Path.wildcard(Path.join(@root, "test/support/**/*.ex"))
  end

  defp serial_scanned_files do
    @root
    |> Path.join("test/**/*.exs")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/browser/"))
  end

  defp relative(path), do: Path.relative_to(path, @root)

  defp numbered_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
  end

  # `[{rel_path, line_no, line}]` — every app/OS env write in `path`, comments included.
  defp env_write_offenders(path) do
    rel = relative(path)

    if rel in @env_write_allowed do
      []
    else
      for {line, line_no} <- numbered_lines(path), Regex.match?(@env_write, line), do: {rel, line_no, line}
    end
  end

  # `[{rel_path, line_no}]` — every `use X, async: false` line with no reason: neither a `#`
  # comment as the nearest non-blank line above it, nor a `@moduledoc` mentioning `async`.
  defp unreasoned_serial_modules(path) do
    rel = relative(path)

    if moduledoc_mentions_async?(File.read!(path)) do
      []
    else
      for {line, line_no, prev} <- with_previous_non_blank(numbered_lines(path)),
          Regex.match?(@serial_use, line),
          not comment?(prev),
          do: {rel, line_no}
    end
  end

  # `[{line, line_no, nearest_non_blank_line_above | nil}]`
  defp with_previous_non_blank(numbered_lines) do
    numbered_lines
    |> Enum.map_reduce(nil, fn {line, line_no}, prev ->
      {{line, line_no, prev}, if(String.trim(line) == "", do: prev, else: line)}
    end)
    |> elem(0)
  end

  defp comment?(nil), do: false
  defp comment?(line), do: String.starts_with?(String.trim_leading(line), "#")

  defp moduledoc_mentions_async?(source) do
    ~r/@moduledoc\s+(?:~[sS])?(?:"""(.*?)"""|"((?:[^"\\]|\\.)*)")/s
    |> Regex.scan(source)
    |> Enum.any?(fn [_ | docs] -> Enum.any?(docs, &String.contains?(&1, "async")) end)
  end

  # --- the guardrail itself --------------------------------------------------

  describe "the guardrail itself" do
    @tag :tmp_dir
    test "an app-env write is reported at its line", %{tmp_dir: tmp} do
      path = Path.join(tmp, "app_env_test.exs")
      File.write!(path, "defmodule X do\n  # setup\n" <> "  " <> "Application." <> "put_env(:relay, :x, 1)" <> "\nend\n")

      assert Enum.map(env_write_offenders(path), fn {_rel, line_no, _line} -> line_no end) == [3]
    end

    @tag :tmp_dir
    test "an OS-env delete is reported at its line", %{tmp_dir: tmp} do
      path = Path.join(tmp, "os_env_test.exs")
      File.write!(path, "defmodule X do\n  " <> "System." <> "delete_env(\"X\")" <> "\nend\n")

      assert Enum.map(env_write_offenders(path), fn {_rel, line_no, _line} -> line_no end) == [2]
    end

    @tag :tmp_dir
    test "an env read is not an offence", %{tmp_dir: tmp} do
      path = Path.join(tmp, "read_test.exs")
      File.write!(path, "defmodule X do\n  Application.get_env(:relay, :x)\nend\n")

      assert env_write_offenders(path) == []
    end

    @tag :tmp_dir
    test "a serial module with no reason is reported at its use line", %{tmp_dir: tmp} do
      path = Path.join(tmp, "serial_test.exs")
      File.write!(path, "defmodule X do\n  use Relay.DataCase, async: false\nend\n")

      assert Enum.map(unreasoned_serial_modules(path), fn {_rel, line_no} -> line_no end) == [2]
    end

    @tag :tmp_dir
    test "a reason comment directly above the use line satisfies the rule", %{tmp_dir: tmp} do
      path = Path.join(tmp, "commented_test.exs")

      File.write!(path, """
      defmodule X do
        # async: false — shares the app-wide Foo singleton (ADR 0009 rule 1).
        use Relay.DataCase, async: false
      end
      """)

      assert unreasoned_serial_modules(path) == []
    end

    @tag :tmp_dir
    test "a moduledoc that explains the serial opt-out satisfies the rule", %{tmp_dir: tmp} do
      path = Path.join(tmp, "moduledoc_test.exs")

      File.write!(path, ~S'''
      defmodule X do
        @moduledoc """
        Reaches the shared-mode branch, so this module stays `async: false` on purpose.
        """
        use Relay.DataCase, async: false
      end
      ''')

      assert unreasoned_serial_modules(path) == []
    end

    @tag :tmp_dir
    test "an async module needs no reason", %{tmp_dir: tmp} do
      path = Path.join(tmp, "async_test.exs")
      File.write!(path, "defmodule X do\n  use RelayWeb.ConnCase, async: true\nend\n")

      assert unreasoned_serial_modules(path) == []
    end
  end
end
