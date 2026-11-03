defmodule HamacaWeb.StoryMapShiftClickHookTest do
  @moduledoc """
  RE502 — ⇧-click on a grid card toggles it into the selection instead of opening the drawer.
  `StoryMapDnD` intercepts it client-side, and `Phoenix.LiveViewTest` never runs a hook, so this
  pins the load-bearing lines at the source (the approach of `HamacaWeb.FocusCardHookTest`).
  The server half — `toggle_card_selection` — is covered by
  `HamacaWeb.BoardLiveStoryMapSelectionTest`.
  """
  use ExUnit.Case, async: true

  @hook Path.expand("../../assets/js/hooks/story_map_dnd.js", __DIR__)

  setup do
    %{src: File.read!(@hook)}
  end

  test "a bubble-phase click listener on the hook's element, so it runs before LiveView's window listener",
       %{src: src} do
    assert src =~ ~S|this.el.addEventListener("click", e => {|
    refute src =~ ~S|addEventListener("click", e => {}, true)|
  end

  test "only a ⇧-click on a grid card of a selectable grid is intercepted", %{src: src} do
    body = click_listener(src)

    assert body =~ "if (!e.shiftKey) return"
    assert body =~ ~S|#${GRID_ID}[data-selectable="true"]|
    assert body =~ "e.target.closest(CARD_SELECTOR)"
    assert body =~ "grid.contains(card)"
  end

  test "it stops the click and pushes toggle_card_selection with the card's ref", %{src: src} do
    body = click_listener(src)

    assert body =~ "e.preventDefault()"
    assert body =~ "e.stopPropagation()"
    assert body =~ ~S|this.pushEvent("toggle_card_selection", {ref: card.dataset.ref})|
  end

  defp click_listener(src) do
    [_before, rest] = String.split(src, ~S|this.el.addEventListener("click", e => {|, parts: 2)
    [body | _after] = String.split(rest, "\n    })", parts: 2)
    body
  end
end
