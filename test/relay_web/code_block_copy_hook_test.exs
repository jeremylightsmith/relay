defmodule RelayWeb.CodeBlockCopyHookTest do
  @moduledoc """
  RE356 — the task body's code-block strip is client-rendered by the `CodeBlockCopy` hook, so its
  artboard contract (`docs/designs/Relay Card Detail v5.dc.html`, "Running fine · DE4": language
  label, `N lines`, a `copy` button that briefly reads `copied`) cannot be asserted through
  `render_component/2`. Pinned at the source, like `RelayWeb.StoryMapCursorsHookTest`; the
  Playwright test `RelayWeb.Browser.TaskCodeBlockTest` proves it in a real browser.
  """
  use ExUnit.Case, async: true

  @hook Path.expand("../../assets/js/hooks/code_block_copy.js", __DIR__)
  @app Path.expand("../../assets/js/app.js", __DIR__)

  setup do
    %{src: File.read!(@hook)}
  end

  test "it decorates each pre > code on mount and on update", %{src: src} do
    assert src =~ ~s|querySelectorAll("pre > code")|
    assert src =~ "mounted()"
    assert src =~ "updated()"
  end

  test "the strip carries the language label, line count and copy button", %{src: src} do
    assert src =~ ~s|"language-"|
    assert src =~ "code-block-strip"
    assert src =~ "code-block-lang"
    assert src =~ "code-block-lines"
    assert src =~ "code-block-copy"
    assert src =~ ~s|"copy"|
    assert src =~ ~s|"copied"|
  end

  test "copying goes through the async clipboard API, never execCommand", %{src: src} do
    assert src =~ "navigator.clipboard.writeText"
    refute src =~ "execCommand"
  end

  test "text is set with textContent, never innerHTML", %{src: src} do
    refute src =~ "innerHTML"
  end

  test "app.js registers the hook" do
    app = File.read!(@app)
    assert app =~ ~s|import CodeBlockCopy from "./hooks/code_block_copy"|
    assert app =~ ~r/hooks: \{[^}]*CodeBlockCopy,/s
  end
end
