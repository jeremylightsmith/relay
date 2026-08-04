defmodule RelayWeb.ThemeTokensTest do
  @moduledoc """
  RE237 guardrail — no hardcoded color literals in the web layer or in the app stylesheets
  outside the daisyUI theme blocks. Colors must come from the semantic tokens so they flip
  with `data-theme`; the mapping from a literal to its token is documented at the top of the
  theming section of `assets/css/app.css`.

  There is deliberately **no** opt-out list — RE237's sweep is finished and the whole of
  `lib/relay_web` plus both stylesheets is scanned. A new exception belongs in `@allowlist`
  (or a `# theme-tokens:allow:` marker) with a comment saying why, never in a re-added pending
  list.

  Known scanner blind spots (`@color_pattern` is intentionally narrow, not exhaustive): it does
  not catch CSS named colors in inline styles (`style="color: white"`), `hsl(...)`/`hsla(...)`,
  or `color(display-p3 ...)`. It also has a false-positive risk on an all-hex-digit fragment
  link (`href="#abc"`, `href="#deadbeef"`) — none have appeared yet, but a future one would need
  an `@allowlist` entry. Tighten or note further gaps in Task 9, which is where the guardrail
  gets proven against a real violation.

  A genuine exception (a color that cannot be a token, like a per-person hash-derived hue) is
  recorded one of two ways: an `@allowlist` entry keyed on the exact matched literal (only safe
  when that literal is unique to the file — a bare `"oklch("` entry would blanket-exempt every
  oklch in the file, since the match text is always just the function-call prefix, not its
  arguments), or a trailing `# theme-tokens:allow: <reason>` comment on the one offending source
  line, which exempts only that line. Prefer the marker when the same pattern (e.g. `oklch(`)
  appears more than once in a file and only one site is a real exception.
  """
  use ExUnit.Case, async: true

  @root File.cwd!()

  @css_files ["assets/css/app.css", "assets/css/storybook.css"]

  # Tailwind's raw palette. daisyUI's semantic names (base-*, primary, secondary, accent,
  # info, success, warning, error, neutral) are tokens, not palette entries, and are allowed.
  @palette ~w(white black slate gray zinc stone red orange amber yellow lime green emerald
              teal cyan sky blue indigo violet purple fuchsia pink rose)

  @color_pattern ~r/oklch\(|rgba?\(|#[0-9a-fA-F]{3}(?:[0-9a-fA-F]{1}|[0-9a-fA-F]{3}|[0-9a-fA-F]{5})?(?![0-9a-zA-Z_-])|\b(?:bg|text|border|fill|stroke|ring|divide|from|to|via)-(?:#{Enum.join(@palette, "|")})(?:-\d{2,3})?\b/

  # Genuine exceptions. {repo-relative path, exact matched literal, why}.
  @allowlist [
    # The Google "G" mark is a brand asset — its four colors are fixed by Google, not by us.
    {"lib/relay_web/controllers/page_html/home.html.heex", "#EA4335", "Google brand mark"},
    {"lib/relay_web/controllers/page_html/home.html.heex", "#4285F4", "Google brand mark"},
    {"lib/relay_web/controllers/page_html/home.html.heex", "#FBBC05", "Google brand mark"},
    {"lib/relay_web/controllers/page_html/home.html.heex", "#34A853", "Google brand mark"},
    # A mask channel, not a color: only the alpha of this gradient is read.
    {"assets/css/app.css", "#000", "mask-image channel, not a color"},
    {"assets/css/storybook.css", "#000", "mask-image channel, not a color"}
  ]

  test "no hardcoded color literals outside the theme blocks" do
    offenders = Enum.flat_map(scanned_files(), &offenders_in/1)

    assert offenders == [], """
    Hardcoded color literals found. Colors must come from the daisyUI semantic tokens so they
    flip with `data-theme`; see the "Token mapping" comment at the top of the theming section
    of assets/css/app.css.

    #{Enum.map_join(offenders, "\n", fn {rel, line_no, match, line} -> "  #{rel}:#{line_no}  #{match}\n      #{String.slice(String.trim(line), 0, 120)}" end)}
    """
  end

  # --- scanner ---------------------------------------------------------------

  defp scanned_files do
    web =
      @root
      |> Path.join("lib/relay_web/**/*.{ex,heex}")
      |> Path.wildcard()

    web ++ Enum.map(@css_files, &Path.join(@root, &1))
  end

  defp relative(path), do: Path.relative_to(path, @root)

  defp offenders_in(path) do
    rel = relative(path)
    ext = Path.extname(path)

    numbered_lines =
      path
      |> File.read!()
      |> strip_comments(ext)
      |> String.split("\n")
      |> Enum.with_index(1)
      |> drop_theme_blocks()

    by_line_no = Map.new(numbered_lines, fn {line, line_no} -> {line_no, line} end)

    numbered_lines
    |> Enum.reject(&whole_line_comment?(&1, ext))
    |> Enum.flat_map(fn {line, line_no} ->
      @color_pattern
      |> Regex.scan(line)
      |> Enum.map(fn [match | _] -> {rel, line_no, match, line} end)
    end)
    |> Enum.reject(fn {rel, line_no, match, line} ->
      allowed?(rel, match, line, Map.get(by_line_no, line_no - 1))
    end)
  end

  # A literal named in a comment is documentation, not a rendered color — the mapping table at
  # the top of app.css quotes the literals it maps FROM. Blank comments out rather than deleting
  # them so line numbers in the failure message stay accurate.
  defp strip_comments(source, ".css"), do: Regex.replace(~r{/\*.*?\*/}s, source, &blank/1)
  defp strip_comments(source, _ex_or_heex), do: Regex.replace(~r{<%!--.*?--%>}s, source, &blank/1)

  defp blank(match), do: String.replace(match, ~r/[^\n]/, " ")

  # Whole-line `#` comments in Elixir/HEEx. Not applied to CSS, where a line may legitimately
  # start with an id selector. Heredocs are NOT parsed: see Global Constraint 9 — never quote a
  # literal inside a @doc.
  defp whole_line_comment?({line, _line_no}, ext) when ext in [".ex", ".heex"],
    do: String.starts_with?(String.trim(line), "#")

  defp whole_line_comment?(_numbered_line, _ext), do: false

  # The `@plugin "../vendor/daisyui-theme" { ... }` blocks are where literals BELONG — that is
  # the one place a raw color defines a token. Everything else in the file is scanned.
  defp drop_theme_blocks(numbered_lines) do
    {kept, _} =
      Enum.reduce(numbered_lines, {[], false}, fn {line, line_no}, {acc, in_theme?} ->
        cond do
          String.contains?(line, ~s(@plugin "../vendor/daisyui-theme")) -> {acc, true}
          in_theme? and String.trim(line) == "}" -> {acc, false}
          in_theme? -> {acc, true}
          true -> {[{line, line_no} | acc], false}
        end
      end)

    Enum.reverse(kept)
  end

  defp allowed?(rel, match, line, prev_line) do
    Enum.any?(@allowlist, fn {path, literal, _why} -> path == rel and literal == match end) or
      marked_allowed?(line) or marked_allowed?(prev_line)
  end

  # A `# theme-tokens:allow: <reason>` marker exempts only the ONE line it annotates — the
  # narrower alternative to an `@allowlist` entry keyed on the matched literal, which for a
  # pattern like "oklch(" would exempt every occurrence in the file (see moduledoc). It's
  # honoured as a trailing comment on the offending line OR as a whole-line comment immediately
  # above it, since `mix format` hoists a trailing comment on a one-line `def ... do: ...` onto
  # its own line above.
  defp marked_allowed?(nil), do: false
  defp marked_allowed?(line), do: String.contains?(line, "theme-tokens:allow")

  describe "the guardrail itself" do
    @tag :tmp_dir
    test "a fresh hardcoded literal is reported with file, line and the literal", %{tmp_dir: tmp} do
      path = Path.join(tmp, "offender.heex")

      File.write!(path, """
      <div class="ok">fine</div>
      <div style="color:oklch(0.55 0.02 255);">not fine</div>
      <div class="bg-white">also not fine</div>
      """)

      assert Enum.map(offenders_in(path), fn {_rel, line_no, match, _line} -> {line_no, match} end) ==
               [{2, "oklch("}, {3, "bg-white"}]
    end

    @tag :tmp_dir
    test "a literal quoted in a comment is documentation, not an offence", %{tmp_dir: tmp} do
      css = Path.join(tmp, "notes.css")
      File.write!(css, ".a { color: var(--color-primary); } /* was oklch(0.60 0.14 250) */\n")
      assert offenders_in(css) == []

      ex = Path.join(tmp, "notes.ex")
      File.write!(ex, "  # the artboard used oklch(0.55 0.02 255) here\n  x = 1\n")
      assert offenders_in(ex) == []
    end

    test "daisyUI semantic classes are not mistaken for the Tailwind palette" do
      for ok <- ~w(bg-base-100 text-base-content/50 border-base-300 bg-primary text-secondary
                   text-neutral-content bg-success border-warning text-error) do
        refute Regex.match?(@color_pattern, ok), "#{ok} is a token, not a palette class"
      end
    end

    test "a fragment link is not mistaken for a hex color" do
      for ok <- ~w(#top #how #flow #stages) do
        refute Regex.match?(@color_pattern, ok)
      end
    end

    test "literals inside a daisyUI theme block are allowed" do
      # app.css and storybook.css are already scanned by the main test; their theme blocks are
      # full of literals, so a green suite proves drop_theme_blocks/1 works. This pins WHY.
      assert File.read!(Path.join(@root, "assets/css/app.css")) =~ "--color-base-100: oklch(1 0 0);"
    end
  end
end
