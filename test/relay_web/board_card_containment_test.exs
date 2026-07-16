defmodule RelayWeb.BoardCardContainmentTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RelayWeb.CoreComponents

  @app_css Path.join([File.cwd!(), "assets", "css", "app.css"])
  @storybook_css Path.join([File.cwd!(), "assets", "css", "storybook.css"])

  # RLY-116 Bug 1: Tailwind's .sr-only is position:absolute. With no positioned
  # ancestor, every card's .card-ref span resolves against the viewport instead
  # of its card, escapes the lane scroller's clipping, and adds ~1.5 screens of
  # phantom document scroll below the board (html.scrollHeight 2459 vs
  # innerHeight 900 at 1440×900). `.board-card { position: relative }` makes
  # the card the containing block, so the lane scroller clips the span again.
  test ".board-card is a containing block for its absolutely-positioned children" do
    for {path, name} <- [{@app_css, "app.css"}, {@storybook_css, "storybook.css"}] do
      assert File.read!(path) =~ ~r/\.board-card\s*\{[^}]*position:\s*relative/s,
             "#{name} must keep the .board-card position:relative rule (RLY-116)"
    end
  end

  test "the card keeps its screen-reader ref span (the absolute child being contained)" do
    html =
      render_component(&CoreComponents.board_card/1,
        id: "card-1",
        ref: "RLY-3",
        title: "Ship MMF 03"
      )

    assert html =~ ~s(<span class="card-ref sr-only">RLY-3</span>)
  end
end
