defmodule RelayWeb.FocusCardHookTest do
  @moduledoc """
  RE326 — `BoardLive.handle_params/3` pushes `focus_card` when the drawer switches or closes, and
  two hooks act on it: `BoardDnD` on the kanban board and `StoryMapDnD` on the story map.
  `Phoenix.LiveViewTest` never runs either hook. The real-browser proof is
  `test/relay_web/browser/board_card_focus_test.exs`, which `mix precommit` excludes, so this pins
  the load-bearing lines at the source and the fast suite still catches a regression. Same
  approach as `RelayWeb.ImageLightboxJsTest` and `RelayWeb.TypingKeyGuardHookTest`.
  """
  use ExUnit.Case, async: true

  @board_dnd Path.expand("../../assets/js/hooks/board_dnd.js", __DIR__)
  @story_map_dnd Path.expand("../../assets/js/hooks/story_map_dnd.js", __DIR__)

  describe "BoardDnD" do
    setup do
      %{src: File.read!(@board_dnd)}
    end

    test "handles focus_card by looking the card up with its own card selector", %{src: src} do
      assert src =~ ~S|const CARD_SELECTOR = ".board-card"|
      assert_focus_card_handler(src)
    end

    test "handles scroll_card by scrolling the card into view without focusing it", %{src: src} do
      assert_scroll_card_handler(src)
    end
  end

  describe "StoryMapDnD" do
    setup do
      %{src: File.read!(@story_map_dnd)}
    end

    test "handles focus_card by looking the card up with its own card selector", %{src: src} do
      assert src =~ ~S|const CARD_SELECTOR = ".story-map-card[data-ref]"|
      assert_focus_card_handler(src)
    end

    test "handles scroll_card by scrolling the card into view without focusing it", %{src: src} do
      assert_scroll_card_handler(src)
    end
  end

  # The handler both hooks carry: look the card up by ref, do nothing when it isn't rendered
  # (never un-hide it), scroll only as far as needed, then focus it.
  defp assert_focus_card_handler(src) do
    assert src =~ ~S|this.handleEvent("focus_card", ({ref}) => {|
    assert src =~ ~S|this.el.querySelector(`${CARD_SELECTOR}[data-ref="${ref}"]`)|
    assert src =~ "if (!card) return"
    assert src =~ ~S|card.scrollIntoView({block: "nearest"})|
    assert src =~ "card.focus()"
  end

  # RE389 — `scroll_card` (nil → A: a click, search result or deep link) reveals the card but must
  # never move keyboard focus. The file legitimately calls card.focus() in focus_card, so the
  # refute runs against the scroll_card handler's body alone.
  defp assert_scroll_card_handler(src) do
    opener = ~S|this.handleEvent("scroll_card", ({ref}) => {|
    assert src =~ opener

    [_before, after_opener] = String.split(src, opener, parts: 2)
    [body | _rest] = String.split(after_opener, "\n    })", parts: 2)

    assert body =~ ~S|this.el.querySelector(`${CARD_SELECTOR}[data-ref="${ref}"]`)|
    assert body =~ "if (!card) return"
    assert body =~ ~S|card.scrollIntoView({block: "nearest"})|
    refute body =~ ".focus("
  end
end
