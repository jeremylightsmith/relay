defmodule RelayWeb.BoardCardContainmentTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RelayWeb.CoreComponents

  @app_css Path.join([File.cwd!(), "assets", "css", "app.css"])
  @storybook_css Path.join([File.cwd!(), "assets", "css", "storybook.css"])

  # RLY-116 Bug 1: an absolutely-positioned child with no positioned ancestor
  # resolves against the viewport instead of its card, escapes the lane
  # scroller's clipping, and adds phantom document scroll below the board
  # (html.scrollHeight 2459 vs innerHeight 900 at 1440×900 when it bit).
  # `.board-card { position: relative }` makes the card the containing block,
  # so the lane scroller clips the card's absolute children again.
  test ".board-card is a containing block for its absolutely-positioned children" do
    for {path, name} <- [{@app_css, "app.css"}, {@storybook_css, "storybook.css"}] do
      assert File.read!(path) =~ ~r/\.board-card\s*\{[^}]*position:\s*relative/s,
             "#{name} must keep the .board-card position:relative rule (RLY-116)"
    end
  end

  # RE321: the ref is visible text at the bottom left of the card, the first
  # item of the always-rendered meta row, not a screen-reader-only span.
  test "the card's ref is visible, first in the card's last (meta) row" do
    html = render_component(&CoreComponents.board_card/1, id: "card-1", ref: "RLY-3", title: "Ship MMF 03")
    doc = LazyHTML.from_fragment(html)

    ref = LazyHTML.query(doc, "article.board-card > .card-meta:last-child > .card-ref:first-child")

    assert Enum.count(ref) == 1
    assert ref |> LazyHTML.text() |> String.trim() == "RLY-3"
    assert LazyHTML.attribute(ref, "class") == ["card-ref"]
    assert doc |> LazyHTML.query(".sr-only") |> Enum.count() == 0

    [style] = LazyHTML.attribute(ref, "style")
    assert style =~ "font-size:10.5px"
    assert style =~ "font-weight:500"
    assert style =~ "font-family:var(--font-mono)"
    assert style =~ "color:color-mix(in oklab, var(--color-base-content) 55%, transparent)"
    assert style =~ "flex:0 0 auto"
    assert style =~ "white-space:nowrap"
  end
end
