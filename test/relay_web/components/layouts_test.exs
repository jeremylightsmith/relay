defmodule RelayWeb.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RelayWeb.Layouts

  @scope %{user: %{id: 1, email: "a@b.co", name: "Ada Lovelace", avatar_url: nil}}

  defp render_app(assigns) do
    assigns =
      Map.merge(%{flash: %{}, current_scope: @scope, inner_block: nil}, assigns)

    render_component(&Layouts.app/1, assigns)
  end

  defp inner_block_slot do
    [%{__slot__: :inner_block, inner_block: fn _, _ -> Phoenix.HTML.raw("x") end}]
  end

  test "always renders the 53px bar with the logo linking to /boards" do
    html = render_app(%{inner_block: inner_block_slot()})

    assert html =~ ~s(id="top-bar")
    assert html =~ "height:53px"
    assert html =~ ~s(id="top-bar-logo")
    assert html =~ ~s(href="/boards")
  end

  test "renders the avatar dropdown with theme toggle and sign out" do
    html = render_app(%{inner_block: inner_block_slot()})

    assert html =~ ~s(id="account-menu")
    assert html =~ ~s(id="sign-out")
    # theme toggle segmented control renders its system/light/dark buttons
    assert html =~ ~s(data-phx-theme="dark")
    # initials fallback (no avatar_url)
    assert html =~ "AL"
  end
end
