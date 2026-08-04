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

  **Both hatches are inventoried here, and that is the point.** `@allowlist` is a list in this
  file, so adding to it is already a reviewable test edit; `@marked_exceptions` gives the marker
  the same property. Without it, an author could exempt a fresh literal by typing a comment into
  the very file being guarded, with no diff under `test/` for a reviewer to catch — a materially
  weaker guardrail than the one this card set out to ship.

  **The marker only works in `.ex`.** It has to survive to the scanner as text on the offending
  line, which rules out `.heex` (`<%!-- … --%>` is blanked by `strip_comments/2` before the scan,
  and HEEx has no `#` comment) and `.css` (`/* … */`, blanked for the same reason). Use an
  `@allowlist` entry there — that is why the four Google-brand hexes in `home.html.heex` and the
  two `#000` mask channels in the stylesheets are listed rather than marked.
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

  # The OTHER hatch: every `# theme-tokens:allow: <reason>` marker in the scanned tree, pinned
  # as {repo-relative path, reason}. A new marker fails this test until it is added here, which
  # is what keeps the hatch reviewable (see moduledoc).
  @marked_exceptions [
    {"lib/relay_web/components/core_components.ex", "no role for a hue"}
  ]

  test "no hardcoded color literals outside the theme blocks" do
    # Guard against a path move silently emptying the scan and making this test pass vacuously.
    refute Enum.empty?(scanned_files()), "scanned_files/0 found nothing to scan — did a path move?"
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

  # The sorted, de-duplicated set of `--*` custom-property NAMES declared in each
  # `@plugin "../vendor/daisyui-theme"` block of a stylesheet (one list per block). Comments are
  # stripped first so a `}` inside a comment cannot truncate a block, and `var(--x)` references
  # are ignored — only declarations (a name immediately followed by `:`) count.
  defp theme_block_token_names(source) do
    stripped = strip_comments(source, ".css")

    ~r|@plugin\s+"\.\./vendor/daisyui-theme"\s*\{(.*?)\}|s
    |> Regex.scan(stripped, capture: :all_but_first)
    |> Enum.map(fn [block] -> block_token_names(block) end)
  end

  defp block_token_names(block) do
    ~r/--([\w-]+)\s*:/
    |> Regex.scan(block, capture: :all_but_first)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

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
      marked_allowed?(line) or hoisted_marker?(prev_line)
  end

  # A `# theme-tokens:allow: <reason>` marker exempts only the ONE line it annotates — the
  # narrower alternative to an `@allowlist` entry keyed on the matched literal, which for a
  # pattern like "oklch(" would exempt every occurrence in the file (see moduledoc). It's
  # honoured as a trailing comment on the offending line OR as a whole-line comment immediately
  # above it, since `mix format` hoists a trailing comment on a one-line `def ... do: ...` onto
  # its own line above.
  #
  # Anchored on the `#` and the trailing `:` so it is a real Elixir comment carrying a reason,
  # not any stray occurrence of the phrase — prose inside a `@doc` heredoc that merely mentions
  # the marker must not silence the line it sits on.
  @marker ~r/#\s*theme-tokens:allow:\s*(?<reason>\S.*?)\s*$/

  defp marked_allowed?(nil), do: false
  defp marked_allowed?(line), do: Regex.match?(@marker, line)

  # The line-above form only counts as a WHOLE-line comment — that is the shape `mix format`
  # produces when it hoists. Accepting a trailing marker as cover for the next line too would
  # let one annotation silence two literals.
  defp hoisted_marker?(nil), do: false

  defp hoisted_marker?(line), do: String.starts_with?(String.trim(line), "#") and marked_allowed?(line)

  test "every theme-tokens:allow marker in the tree is inventoried here" do
    found =
      Enum.flat_map(scanned_files(), fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.flat_map(fn line ->
          case Regex.named_captures(@marker, line) do
            %{"reason" => reason} -> [{relative(path), reason}]
            nil -> []
          end
        end)
      end)

    assert Enum.sort(found) == Enum.sort(@marked_exceptions), """
    The `# theme-tokens:allow:` inventory is out of date.

    A marker exempts a color literal from the guardrail from inside the file being guarded, so
    it only stays reviewable while every one of them is listed in `@marked_exceptions`. If you
    added an exception, add it here too — and justify it in review. If you removed a literal,
    drop its entry.

      in the tree: #{inspect(found)}
      inventoried: #{inspect(@marked_exceptions)}
    """
  end

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

    @tag :tmp_dir
    test "the marker must be a `#` comment carrying a reason", %{tmp_dir: tmp} do
      path = Path.join(tmp, "marked.ex")

      File.write!(path, """
        # theme-tokens:allow: seeded per-entity hue
        def a, do: "oklch(0.62 0.13 10)"
        def b, do: "oklch(0.62 0.13 20)" # theme-tokens:allow: ditto
        def c, do: "oklch(0.62 0.13 30)"
        @doc "prose that merely says theme-tokens:allow proves nothing"
        def d, do: "oklch(0.62 0.13 40)" # theme-tokens:allow
      """)

      # a and b are exempt; c is unmarked; d's marker carries no reason, and the bare mention in
      # the @doc above it is prose, not an opt-out.
      assert Enum.map(offenders_in(path), fn {_rel, line_no, _match, _line} -> line_no end) == [4, 6]
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

  # Dark mode only works if the dark theme block defines every token the light block does: a token
  # present in light but missing from dark silently falls back to the light value, and the ~2,000
  # `var(--color-*)` references this branch introduced all depend on that parity. The two
  # stylesheets must mirror each other too (`docs_styling_test.exs` establishes the same rule for
  # selectors). So all four `@plugin "../vendor/daisyui-theme"` blocks — light + dark in app.css,
  # light + dark in storybook.css — must declare the identical set of token names.
  test "all four daisyUI theme blocks declare the identical token-name set" do
    blocks =
      for file <- @css_files,
          names <- theme_block_token_names(File.read!(Path.join(@root, file))) do
        {file, names}
      end

    assert length(blocks) == 4,
           ~s(expected 4 `@plugin "../vendor/daisyui-theme"` blocks ) <>
             "(light + dark in each stylesheet), found #{length(blocks)}"

    [{ref_file, reference} | _] = blocks
    refute Enum.empty?(reference), "no `--*` tokens found in the theme blocks — did the regex drift?"

    for {file, names} <- blocks do
      assert names == reference,
             "#{file}: theme token set differs from #{ref_file}.\n" <>
               "  missing here: #{inspect(reference -- names)}\n" <>
               "  extra here:   #{inspect(names -- reference)}"
    end
  end
end
