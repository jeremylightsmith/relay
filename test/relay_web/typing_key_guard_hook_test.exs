defmodule RelayWeb.TypingKeyGuardHookTest do
  @moduledoc """
  RE306 — the typing guard's job is to match keys exactly the way LiveView matches `phx-key`.
  It cannot be exercised through `render_component/2` or `render_keydown/3` (both bypass the
  client entirely), and the real-browser test in `test/relay_web/browser/typing_key_guard_test.exs`
  can only observe the outcomes, not the reasons. This pins the reasons at the source, the same
  way `RelayWeb.StoryMapCursorsHookTest` pins an artboard's values: the divergence that caused
  this bug was invisible until someone typed a capital letter.
  """
  use ExUnit.Case, async: true

  @hook Path.expand("../../assets/js/hooks/typing_key_guard.js", __DIR__)

  setup do
    %{src: File.read!(@hook)}
  end

  test "both sides of the key comparison are case-folded, as LiveView's own matching is", %{src: src} do
    assert src =~ ".map(key => key.toLowerCase())",
           "the declared data-guard-keys must be lowercased once at mount"

    assert src =~ "const key = e.key && e.key.toLowerCase()",
           "the incoming key must be lowercased before comparison (and guarded against a " <>
             "keyless keydown, which Chrome autocomplete fires)"

    refute src =~ "includes(e.key)",
           "comparing the raw e.key is the RE306 bug: LiveView matches phx-key case-insensitively"
  end

  test "a modifier chord is swallowed wherever focus is", %{src: src} do
    assert src =~ "e.ctrlKey || e.metaKey || e.altKey",
           "Ctrl/Cmd/Alt chords belong to the browser and the caret, not to a single-letter " <>
             "app shortcut"
  end

  test "Shift is deliberately NOT a swallowed modifier", %{src: src} do
    refute src =~ "shiftKey",
           "Shift is how you type a capital: swallowing it would break Shift+T as a shortcut, " <>
             "and the case-folded match plus the text-field check already cover typing"
  end

  test "the field check and the capture-phase listener are unchanged", %{src: src} do
    assert src =~ ~s[tag === "INPUT" || tag === "TEXTAREA" || (t && t.isContentEditable)]
    assert src =~ "e.stopImmediatePropagation()"
    assert src =~ ~s[window.addEventListener("keydown", this.onKeydown, true)]
    assert src =~ ~s[window.removeEventListener("keydown", this.onKeydown, true)]
  end

  test "both mount points share this one implementation", %{src: _src} do
    app = File.read!(Path.expand("../../assets/js/app.js", __DIR__))

    assert app =~ ~s(import TypingKeyGuard from "./hooks/typing_key_guard")
    assert app =~ "ArrowKeyGuard: TypingKeyGuard,"
    assert app =~ "TypingKeyGuard,"
  end
end
