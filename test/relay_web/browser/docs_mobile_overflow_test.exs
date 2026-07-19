defmodule RelayWeb.Browser.DocsMobileOverflowTest do
  @moduledoc """
  Real-browser (Playwright) regression test: no docs page may scroll horizontally
  on a phone.

  RLY-171 published `docs/architecture/` to the public site, which brought two
  kinds of content the docs CSS had never had to lay out at 390px:

    * wide reference tables (runtime's PubSub topic table renders ~827px), and
    * long unbreakable inline `code` tokens (runner cites
      `lib/relay_web/controllers/api/node_job_controller.ex`, ~411px).

  Both widened the document itself, so the whole page — nav, sidebar, article —
  scrolled sideways on a phone. The fix keeps each one in its own scroll
  container (`.docs table` is `display: block; overflow-x: auto`) or lets it wrap
  (`.docs code` is `overflow-wrap: break-word`). Only a real browser computes
  this geometry, so that is the only honest assertion.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame

  @moduletag :playwright
  # iPhone 14 / 15 logical width — the narrowest viewport the docs site targets.
  @moduletag browser_context_opts: [viewport: %{width: 390, height: 844}]

  # One page per failure mode RLY-171 introduced.
  @pages [
    {"/docs/architecture-runtime", "a wide PubSub topic table"},
    {"/docs/architecture-runner", "long inline code file paths"}
  ]

  for {path, why} <- @pages do
    test "#{path} does not scroll horizontally at 390px (#{why})", %{conn: conn} do
      conn
      |> visit(unquote(path))
      # The article is server-rendered, so waiting on it is enough to measure
      # layout; mermaid figures only ever shrink the document, never widen it.
      |> assert_has(".docs")
      |> unwrap(fn %{frame_id: frame_id} ->
        {:ok, metrics} =
          Frame.evaluate(frame_id,
            expression: """
            (() => {
              const de = document.documentElement;
              // Name the widest thing sticking out past the viewport, so a
              // failure says which element regressed rather than just a number.
              let worst = null;
              for (const el of document.querySelectorAll('.docs *')) {
                const right = el.getBoundingClientRect().right;
                // Content *inside* a scroller is contained by design; the scroller
                // itself still counts, since that is what would widen the page.
                const scroller = el.closest('pre, table, figure.docs-mermaid');
                if (right > de.clientWidth + 1 && (!scroller || scroller === el)) {
                  if (!worst || right > worst.right) {
                    worst = {right: Math.round(right), tag: el.tagName,
                             text: (el.textContent || '').trim().slice(0, 60)};
                  }
                }
              }
              return {scrollWidth: de.scrollWidth, clientWidth: de.clientWidth, worst: worst};
            })()
            """,
            timeout: 2_000
          )

        assert metrics["scrollWidth"] <= metrics["clientWidth"] + 1,
               "#{unquote(path)} scrolls horizontally at 390px: document scrollWidth " <>
                 "#{metrics["scrollWidth"]} > clientWidth #{metrics["clientWidth"]}. " <>
                 "Widest overflowing element: #{inspect(metrics["worst"])}"
      end)
    end
  end

  test "a wide docs table scrolls inside itself instead of widening the page", %{conn: conn} do
    conn
    |> visit("/docs/architecture-runtime")
    |> assert_has(".docs table")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, table} =
        Frame.evaluate(frame_id,
          expression: """
          (() => {
            const wide = [...document.querySelectorAll('.docs table')]
              .find((t) => t.scrollWidth > t.clientWidth + 1);
            if (!wide) return {found: 0};
            return {found: 1, scrollWidth: wide.scrollWidth, clientWidth: wide.clientWidth,
                    overflowX: getComputedStyle(wide).overflowX};
          })()
          """,
          timeout: 2_000
        )

      assert table["found"] == 1,
             "expected the PubSub topic table to be wider than a 390px viewport; if the " <>
               "table shrank, this regression test no longer proves anything"

      assert table["overflowX"] in ["auto", "scroll"],
             "the wide table must own its horizontal scroll, got overflow-x: #{table["overflowX"]}"
    end)
  end
end
