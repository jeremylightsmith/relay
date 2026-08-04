defmodule RelayWeb.CommitPillShadowTest do
  @moduledoc """
  RE237 review fix — `.commit-pill`'s box-shadow color-mixed with `--color-base-content`, which
  under `data-theme="dark"` is a near-white token (`oklch(0.96 0.006 255)`). Mixing a shadow color
  with base-content in dark mode reads as a light halo behind the floating pill instead of a
  shadow — the same failure `.modal-scrim`'s dark override (above it in app.css) already exists to
  prevent. This also restores the light-mode alpha to what the original literal implied: the swept
  literal was `oklch(0.5 0.03 255 / 0.18)`, an 18%-alpha mid-grey; Rule N maps L 0.5 to P 70, so
  the alpha-faithful equivalent is 70% of 18% ~= 13%, not a bare 18% of base-content.
  """
  use ExUnit.Case, async: true

  @app_css Path.join([File.cwd!(), "assets", "css", "app.css"])
  @storybook_css Path.join([File.cwd!(), "assets", "css", "storybook.css"])

  test "the commit-pill shadow is alpha-faithful in light mode and stays a shadow (not a halo) in dark mode" do
    for css <- [File.read!(@app_css), File.read!(@storybook_css)] do
      assert css =~
               ~r/\.commit-pill\s*\{[^}]*box-shadow:\s*0 6px 18px color-mix\(in oklab, var\(--color-base-content\) 13%, transparent\)/s,
             "light-mode .commit-pill shadow should mix 13% base-content (alpha-faithful), not 18%"

      assert css =~
               ~r/\[data-theme="dark"\]\s*\.commit-pill\s*\{[^}]*box-shadow:\s*0 6px 18px color-mix\(in oklab, var\(--color-base-200\)/s,
             "dark-mode .commit-pill shadow should mix with base-200, not base-content"

      refute css =~ ~r/\[data-theme="dark"\]\s*\.commit-pill\s*\{[^}]*base-content/s,
             "dark-mode .commit-pill shadow must not mix with base-content — it would read as a light halo"
    end
  end
end
