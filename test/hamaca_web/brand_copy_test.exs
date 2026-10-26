defmodule HamacaWeb.BrandCopyTest do
  @moduledoc """
  RE477 guardrail — the product a person reads is Hamaca, so no rendered copy in the web layer
  or the billing emails may say "Relay".

  Scans `lib/hamaca_web/**/*.{ex,heex,eex}` and `lib/hamaca/billing/**/*.ex` for a whole-word,
  case-sensitive `Relay`. What is NOT rendered copy is blanked first (keeping line numbers):
  `<%!-- … --%>` comments, whole-line and trailing `#` comments, and `@moduledoc` / `@doc` /
  `@typedoc` strings. Module references (`Relay.Cards`, `alias Relay.{…}`), the `./relay`
  command, `relay.md` and artboard file names (`*.dc.html`) are dropped too — those are renamed
  by RE478 / RE481, not here.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  @brand ~r/\bRelay\b/

  test "no rendered copy in the web layer or billing says Relay" do
    files = scanned_files()
    refute Enum.empty?(files), "scanned_files/0 found nothing to scan — did a path move?"

    offenders =
      Enum.flat_map(files, fn path ->
        rel = Path.relative_to(path, @root)

        path
        |> File.read!()
        |> offenders_in(Path.extname(path))
        |> Enum.map(fn {line_no, line} -> "  #{rel}:#{line_no}: #{String.trim(line)}" end)
      end)

    assert offenders == [], """
    Rendered copy still says "Relay" — the product name a person reads is Hamaca. Use
    `Hamaca.Brand.name()` for a code-level name, or the literal "Hamaca" in prose.

    #{Enum.join(offenders, "\n")}
    """
  end

  describe "the scanner" do
    test "flags rendered markup" do
      assert length(offenders_in(~s(<span>Relay</span>), ".heex")) == 1
    end

    test "skips a @moduledoc heredoc" do
      assert offenders_in(~s(@moduledoc """\nRelay docs\n"""), ".ex") == []
    end

    test "skips a whole-line comment" do
      assert offenders_in("# Relay comment", ".ex") == []
    end

    test "skips a trailing comment" do
      assert offenders_in(~s(x = 1 # Relay comment), ".ex") == []
    end

    test "skips a single-line @doc" do
      assert offenders_in(~s(@doc "Relay docs"), ".ex") == []
    end

    test "skips a HEEx comment" do
      assert offenders_in("<%!-- Relay\nstill a comment --%>", ".heex") == []
    end

    test "skips a module reference" do
      assert offenders_in("alias Relay.Cards", ".ex") == []
    end

    test "skips the ./relay command" do
      assert offenders_in("run ./relay card", ".ex") == []
    end

    test "keeps line numbers after a blanked block" do
      source = ~s(@moduledoc """\nRelay docs\n"""\n<p>Relay</p>)
      assert [{4, _line}] = offenders_in(source, ".ex")
    end
  end

  # --- scanner ---------------------------------------------------------------

  defp scanned_files do
    Path.wildcard(Path.join(@root, "lib/hamaca_web/**/*.{ex,heex,eex}")) ++
      Path.wildcard(Path.join(@root, "lib/hamaca/billing/**/*.ex"))
  end

  # `[{line_no, line}]` for every line of `source` whose rendered copy says "Relay".
  defp offenders_in(source, ext) do
    source
    |> blank(~r{<%!--.*?--%>}s)
    |> blank(~r/@(?:moduledoc|doc|typedoc)\s+(?:~[sS])?"""(?:.|\n)*?"""/)
    |> blank(~r/@(?:moduledoc|doc|typedoc)\s+(?:~[sS])?"(?:[^"\\\n]|\\.)*"/)
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _line_no} -> String.starts_with?(String.trim(line), "#") end)
    |> Enum.map(fn {line, line_no} -> {line_no, line, strip(line, ext)} end)
    |> Enum.filter(fn {_line_no, _line, scanned} -> Regex.match?(@brand, scanned) end)
    |> Enum.map(fn {line_no, line, _scanned} -> {line_no, line} end)
  end

  # A trailing Elixir/shell comment is a `#` after whitespace, followed by whitespace — which
  # never matches `#{interpolation}` or an `href="#anchor"`. HEEx has no `#` comment syntax.
  defp strip(line, ".heex"), do: drop_tokens(line)
  defp strip(line, _ex_or_eex), do: line |> String.replace(~r/\s#\s.*$/, "") |> drop_tokens()

  defp drop_tokens(line) do
    line
    |> String.replace(~r/\bRelay(?:Web)?\.(?=[A-Z{])/, "")
    |> String.replace("./relay", "")
    |> String.replace("relay.md", "")
    |> String.replace(~r/[\w .-]*\.dc\.html/, "")
  end

  # Replace every match with spaces, keeping its newlines so line numbers stay accurate.
  defp blank(source, pattern), do: Regex.replace(pattern, source, &String.replace(&1, ~r/[^\n]/, " "))
end
