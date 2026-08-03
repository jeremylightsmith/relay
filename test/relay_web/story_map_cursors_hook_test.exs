defmodule RelayWeb.StoryMapCursorsHookTest do
  @moduledoc """
  RE257 — the cursor hook is client-rendered, so its artboard values
  (`docs/designs/Relay Story Map.dc.html`, `showPresence`, lines 117-123) cannot be asserted
  through `render_component/2`. This pins them at the source, the same way
  `RelayWeb.StorybookStoriesTest` pins story contents: "matches the mockup" is only a
  deliverable if it is checked.
  """
  use ExUnit.Case, async: true

  @hook Path.expand("../../assets/js/hooks/story_map_cursors.js", __DIR__)

  setup do
    %{src: File.read!(@hook)}
  end

  test "the arrow is the artboard's 16x16 SVG and path", %{src: src} do
    assert src =~ ~s(width="16" height="16" viewBox="0 0 16 16")
    assert src =~ ~s(d="M1 1 L1 12 L4 9 L6.5 14 L8.5 13 L6 8 L10 8 Z")
    assert src =~ ~s(stroke="white")
    assert src =~ ~s(stroke-width="1")
  end

  test "the name chip carries the artboard's label tokens", %{src: src} do
    assert src =~ "left:14px"
    assert src =~ "top:12px"
    assert src =~ "font-size:9.5px"
    assert src =~ "font-weight:600"
    assert src =~ "padding:2px 6px"
    assert src =~ "border-radius:5px"
    assert src =~ "white-space:nowrap"
    assert src =~ "var(--font-mono)"
  end

  test "the cursor node is an absolutely positioned, non-interactive z-40 overlay", %{src: src} do
    assert src =~ "position:absolute"
    assert src =~ "z-index:40"
    assert src =~ "pointer-events:none"
  end

  test "the artboard's decorative keyframes are deliberately NOT copied", %{src: src} do
    refute src =~ "smcursorA"
    refute src =~ "smcursorB"
    refute src =~ "@keyframes"
  end

  test "the hook is registered in the bundle" do
    app = File.read!(Path.expand("../../assets/js/app.js", __DIR__))

    assert app =~ ~s(import StoryMapCursors from "./hooks/story_map_cursors")
    assert app =~ "StoryMapCursors,"
  end
end
