defmodule RelayWeb.RootLayoutThemeTest do
  @moduledoc """
  RE237 — the theme resolver is a synchronous inline <head> script (that is what prevents a
  flash of the wrong theme), so there is nothing server-rendered to assert against. These
  tests pin the source of that script instead.
  """
  use ExUnit.Case, async: true

  @root_layout Path.join([File.cwd!(), "lib", "relay_web", "components", "layouts", "root.html.heex"])

  setup do
    {:ok, src: File.read!(@root_layout)}
  end

  test "<html> carries no static data-theme — the resolver owns it", %{src: src} do
    assert src =~ ~s(<html lang="en">)
    refute src =~ ~s(data-theme="light")
  end

  test "the resolver sets both the resolved theme and the raw preference", %{src: src} do
    assert src =~ ~s|setAttribute("data-theme", resolved)|
    assert src =~ ~s|setAttribute("data-theme-pref", pref)|
  end

  test "system mode resolves through matchMedia and re-resolves on OS change", %{src: src} do
    assert src =~ ~s|matchMedia("(prefers-color-scheme: dark)")|
    assert src =~ ~s|mq.addEventListener("change"|
  end

  test "every localStorage access is wrapped in try/catch (Safari private mode throws)", %{src: src} do
    for access <- ["getItem(\"phx:theme\")", "setItem(\"phx:theme\"", "removeItem(\"phx:theme\")"] do
      assert src =~ access
    end

    assert src =~ "catch (e) {}"
  end

  test "cross-tab and toggle listeners are both wired", %{src: src} do
    assert src =~ ~s|addEventListener("storage"|
    assert src =~ ~s|addEventListener("phx:set-theme"|
  end

  test "the QUICKFIX force-light block is gone", %{src: src} do
    refute src =~ "QUICKFIX"
  end
end
