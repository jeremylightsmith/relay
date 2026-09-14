defmodule RelayWeb.ImageLightboxJsTest do
  @moduledoc """
  RE322 — the carousel's grouping, wrap-around and key isolation live in
  `assets/js/image_lightbox.js`, which `Phoenix.LiveViewTest` never runs. The real-browser proof is
  `test/relay_web/browser/image_carousel_test.exs`, which `mix precommit` excludes; this pins the
  load-bearing lines at the source so the fast suite still catches a regression — the same way
  `RelayWeb.TypingKeyGuardHookTest` pins RE306.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RelayWeb.CoreComponents

  @js Path.expand("../../assets/js/image_lightbox.js", __DIR__)

  setup do
    %{src: File.read!(@js)}
  end

  test "keys are taken in the capture phase on window, before LiveView's window keydown bindings", %{src: src} do
    assert src =~ ~s[window.addEventListener("keydown", onKeydown, true)]
  end

  test "keys are only touched while the viewer is open", %{src: src} do
    assert src =~ "if (!dialog || !dialog.open) return"
  end

  test "handled keys never reach the drawer's prev_card/next_card/close_drawer bindings", %{src: src} do
    assert src =~ "e.stopImmediatePropagation()"
    # Esc closes the viewer explicitly — its default action is not relied on.
    assert src =~ "dialog.close()"
  end

  test "keys are case-folded like LiveView's phx-key, and chords are left alone", %{src: src} do
    assert src =~ "const key = e.key && e.key.toLowerCase()"
    assert src =~ "e.ctrlKey || e.metaKey || e.altKey"
  end

  test "D4 — j is next and k is previous; arrows map as expected", %{src: src} do
    assert src =~ "const STEPS = {arrowleft: -1, k: -1, arrowright: 1, j: 1}"
  end

  test "D1 — the set is the clicked image's own group", %{src: src} do
    assert src =~ ~s[const GROUP = "#ai-result-screens, .md, .docs"]
    assert src =~ ~s[const SELECTOR = ".md img, .docs img, #ai-result-screens img"]
  end

  test "D2 — stepping wraps at both ends", %{src: src} do
    assert src =~ "(index + delta + images.length) % images.length"
  end

  test "every image-lightbox id the JS looks up is rendered by image_lightbox/1", %{src: src} do
    ids =
      ~r/"(image-lightbox(?:-[a-z]+)?)"/
      |> Regex.scan(src, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert "image-lightbox-counter" in ids, "the scan found no carousel ids — did the JS move?"

    html = render_component(&CoreComponents.image_lightbox/1, [])

    for id <- ids do
      assert html =~ ~s(id="#{id}"), "image_lightbox.js looks up ##{id}, which image_lightbox/1 does not render"
    end
  end
end
