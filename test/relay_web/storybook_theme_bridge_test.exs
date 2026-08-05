defmodule RelayWeb.StorybookThemeBridgeTest do
  @moduledoc """
  RE237 — /storybook renders under PhoenixStorybook's own root layout, not root.html.heex, so the
  app's theme resolver never runs there and `<html>` carried no `data-theme`: every
  `[data-theme=dark]` rule in storybook.css was unreachable and the storybook was stuck light
  while the rest of the app was dark.

  `assets/js/storybook.js` is the bridge, and — like the resolver it mirrors — it is a
  synchronous `<head>` script with nothing server-rendered to assert against. So these tests pin
  its source, the same way `RelayWeb.RootLayoutThemeTest` pins the resolver's. The regression
  that made this file necessary is a silent one (the storybook simply stops flipping), which is
  exactly the kind that needs a test rather than a reviewer.
  """
  use ExUnit.Case, async: true

  @bridge Path.join([File.cwd!(), "assets", "js", "storybook.js"])

  setup do
    {:ok, src: File.read!(@bridge)}
  end

  test "PhoenixStorybook renders its own color-mode switcher" do
    assert RelayWeb.Storybook.config(:color_mode) == true
  end

  test "the bridge is wired up as the storybook's js_path" do
    assert RelayWeb.Storybook.config(:js_path) == "/assets/js/storybook.js"
  end

  test "the bridge is live code, not the commented-out boilerplate it replaced", %{src: src} do
    refute src =~ "window.storybook = { Hooks, Params, Uploaders }"

    executable =
      src
      |> String.split("\n")
      |> Enum.reject(&(String.starts_with?(String.trim(&1), "//") or String.trim(&1) == ""))

    refute executable == []
  end

  test "it sets both the resolved theme and the raw preference, like the app resolver", %{src: src} do
    assert src =~ ~s|setAttribute("data-theme", resolved)|
    assert src =~ ~s|setAttribute("data-theme-pref", pref)|
  end

  test "the app's preference is the source of truth, not a storybook-only setting", %{src: src} do
    assert src =~ ~s|const APP_KEY = "phx:theme"|
    assert src =~ "localStorage.getItem(APP_KEY)"
    assert src =~ "localStorage.setItem(APP_KEY, pref)"
    assert src =~ "localStorage.removeItem(APP_KEY)"
  end

  test "the preference is mirrored into PhoenixStorybook's key so its chrome agrees", %{src: src} do
    assert src =~ ~s|const PSB_KEY = "psb_selected_color_mode"|
    assert src =~ "localStorage.setItem(PSB_KEY, pref)"
  end

  test "system mode resolves through matchMedia and re-resolves on OS change", %{src: src} do
    assert src =~ ~s|matchMedia("(prefers-color-scheme: dark)")|
    assert src =~ ~s|mq.addEventListener("change"|
  end

  test "the storybook's own switcher writes back, so the choice follows you into the app", %{src: src} do
    assert src =~ ~s|addEventListener("psb:set-color-mode"|
  end

  test "cross-document changes propagate to the story iframes and other tabs", %{src: src} do
    assert src =~ ~s|addEventListener("storage"|
  end

  test "every localStorage access is wrapped in try/catch (Safari private mode throws)", %{src: src} do
    assert src =~ "catch (e) {}"
    assert src =~ "return \"system\";"
  end

  test "storybook.css no longer claims the dark rules are unreachable" do
    css = File.read!(Path.join([File.cwd!(), "assets", "css", "storybook.css"]))

    refute css =~ "unreachable on that route"
    assert css =~ "assets/js/storybook.js is the bridge"
  end
end
