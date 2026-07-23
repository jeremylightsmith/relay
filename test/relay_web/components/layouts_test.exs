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

  test "hides the wordmark text below md while keeping the logo icon" do
    html = render_app(%{inner_block: inner_block_slot()})

    # wordmark span is hidden until md; logo img is always present
    assert html =~ ~s(class="hidden md:inline text-[15px] font-semibold tracking-[-0.02em]")
    assert html =~ ~s(alt="Relay")
  end

  test "reconnect banners read 'Relay is updating' as calm info alerts" do
    html = render_app(%{inner_block: inner_block_slot()})

    assert html =~ ~s(id="client-error")
    assert html =~ ~s(id="server-error")
    assert html =~ "Relay is updating"
    assert html =~ "Standby"
    assert html =~ "alert-info"

    # the old red-error copy is gone
    refute html =~ "We can't find the internet"
    refute html =~ "Something went wrong"

    # the disconnect/connect visibility hooks are preserved
    assert html =~ "phx-disconnected"
    assert html =~ "phx-connected"
  end

  test "renders the avatar dropdown with sign out" do
    html = render_app(%{inner_block: inner_block_slot()})

    assert html =~ ~s(id="account-menu")
    assert html =~ ~s(id="sign-out")
    # QUICKFIX: theme toggle hidden while dark mode is broken (forced light).
    refute html =~ ~s(data-phx-theme="dark")
    # initials fallback (no avatar_url)
    assert html =~ "AL"
  end
end
