defmodule RelayWeb.BrowserNotifyHookTest do
  @moduledoc """
  RE399 — source pins for the `BrowserNotify` JS hook's invariants that a single-page Playwright
  test cannot observe (see `RelayWeb.Browser.BrowserNotifyTest` for the behavior):

    * the permission prompt is only ever raised by the user's Enable click, never on load;
    * several open tabs fire one OS notification / horn per event — the Web Lock named
      `"relay:notify:" <> id`, taken with `ifAvailable: true`, picks a single winner;
    * no color literal — the favicon dot reads the theme's `--color-warning` token;
    * the horn URL comes from the server (`data-sound`), never a hard-coded path;
    * toast text is written as text, never parsed as HTML.

  Same style as `RelayWeb.TypingKeyGuardHookTest`.
  """
  use ExUnit.Case, async: true

  @hook Path.expand("../../assets/js/hooks/browser_notify.js", __DIR__)
  @app Path.expand("../../assets/js/app.js", __DIR__)

  setup do
    %{src: File.read!(@hook)}
  end

  test "requestPermission is called exactly once, from the #notify-enable click path", %{src: src} do
    assert length(String.split(src, "requestPermission")) == 2,
           "Notification.requestPermission() must have exactly one call site"

    [before, _after] = String.split(src, "requestPermission")
    enable_at = :binary.matches(before, "notify-enable")
    assert enable_at != [], "the requestPermission call must follow the #notify-enable click check"

    refute mounted_body(src) =~ "requestPermission", "mounted() must never ask for permission"
  end

  test "the single firer takes a Web Lock named relay:notify:<id> with ifAvailable", %{src: src} do
    assert src =~ "navigator.locks.request("
    assert src =~ "ifAvailable: true"
    assert src =~ ~s("relay:notify:" + )
  end

  test "the favicon dot color is the --color-warning token and the source has no color literal",
       %{src: src} do
    assert src =~ ~s[getPropertyValue("--color-warning")]
    refute src =~ ~r/#[0-9a-fA-F]{3,8}\b/, "no hex color literal"
    refute src =~ "rgb("
    refute src =~ "oklch("
  end

  test "the horn URL is read from data-sound, never hard-coded", %{src: src} do
    assert src =~ "dataset.sound"
    refute src =~ "/sounds/"
  end

  test "toast fields are written with textContent, never innerHTML", %{src: src} do
    assert src =~ "textContent"
    refute src =~ "innerHTML"
  end

  test "app.js registers the hook as BrowserNotify" do
    app = File.read!(@app)
    assert app =~ ~s(import BrowserNotify from "./hooks/browser_notify")
    assert app =~ "BrowserNotify,"
  end

  # The text of the hook object's `mounted() { … }` method, up to its closing brace at the
  # method's indentation.
  defp mounted_body(src) do
    case Regex.run(~r/\n(\s*)mounted\(\)\s*\{(.*?)\n\1\}/s, src) do
      [_, _indent, body] -> body
      nil -> flunk("no mounted() method found in the hook")
    end
  end
end
