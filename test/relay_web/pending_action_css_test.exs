defmodule RelayWeb.PendingActionCssTest do
  @moduledoc """
  RE394 — the shared client-side "pressed face" for action buttons is one unlayered CSS block in
  app.css, mirrored byte-for-byte into storybook.css. These tests pin the contract the
  `<.button pending>` / `<.action_group>` markup relies on.
  """
  use ExUnit.Case, async: true

  @app_css Path.join([File.cwd!(), "assets", "css", "app.css"])
  @storybook_css Path.join([File.cwd!(), "assets", "css", "storybook.css"])

  @begin_marker "/* RE394 pending actions — begin */"
  @end_marker "/* RE394 pending actions — end */"

  defp block(path) do
    css = File.read!(path)

    case String.split(css, [@begin_marker, @end_marker]) do
      [_, inner, _] -> inner
      _ -> flunk("#{path} must contain exactly one #{@begin_marker} … #{@end_marker} block")
    end
  end

  test "the pressed-face rules exist in both stylesheets" do
    for path <- [@app_css, @storybook_css] do
      css = block(path)

      assert css =~ ".pending-action.phx-click-loading", path
      assert css =~ ~s(.pending-action[type="submit"].phx-submit-loading), path
      assert css =~ "filter: brightness(.85)", path

      assert css =~
               "inset 0 2px 4px color-mix(in oklab, var(--color-base-content) 25%, transparent)",
             path

      assert css =~ ~r/\.action-group:has\([^{]*\{[^}]*opacity: \.4;[^}]*pointer-events: none/s, path
      assert css =~ ~r/\.pending-stack > \*\s*\{[^}]*grid-area: 1 \/ 1/s, path
      assert css =~ ".pending-status", path
      assert css =~ "--btn-fg: var(--color-primary-content)", path
    end
  end

  test "a left-aligned pending row keeps its faces anchored left, not centred in the stack" do
    for path <- [@app_css, @storybook_css] do
      assert block(path) =~
               ~r/\.pending-action\.text-left \.pending-stack\s*\{[^}]*justify-items: start/s,
             path
    end
  end

  test "the RE394 block is byte-identical in app.css and storybook.css" do
    assert block(@app_css) == block(@storybook_css)
  end

  test "the RE394 block carries no colour literals" do
    for path <- [@app_css, @storybook_css] do
      css = block(path)
      refute css =~ "oklch(", path
      refute css =~ ~r/#[0-9a-fA-F]{3,8}\b/, path
      refute css =~ "rgb(", path
      refute css =~ "hsl(", path
    end
  end
end
