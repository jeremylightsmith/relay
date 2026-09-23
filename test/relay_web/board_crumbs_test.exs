defmodule RelayWeb.BoardCrumbsTest do
  use ExUnit.Case, async: true

  alias RelayWeb.BoardCrumbs
  alias RelayWeb.BoardSettingsLive

  @board %Schemas.Board{name: "Payments", slug: "payments"}

  test "board/1 is just the Boards root, carrying the squares icon" do
    assert [
             %{
               id: "top-bar-crumb-boards",
               label: "Boards",
               to: "/boards",
               icon: "hero-squares-2x2"
             }
           ] = BoardCrumbs.board(@board)
  end

  test "settings_section/1 is Boards / <board> / Settings, each linking to its page" do
    assert [
             %{id: "top-bar-crumb-boards", to: "/boards"},
             %{id: "top-bar-crumb-board", label: "Payments", to: "/board/payments"},
             %{id: "top-bar-crumb-settings", label: "Settings", to: "/board/payments/settings"}
           ] = BoardCrumbs.settings_section(@board)
  end

  test "flows/1 adds the Flows crumb, labelled by the settings section it opens" do
    flows_label = BoardSettingsLive.section_label(:flows)

    assert [
             %{id: "top-bar-crumb-boards"},
             %{id: "top-bar-crumb-board"},
             %{id: "top-bar-crumb-settings"},
             %{
               id: "top-bar-crumb-flows",
               label: ^flows_label,
               to: "/board/payments/settings?section=flows"
             }
           ] = BoardCrumbs.flows(@board)
  end

  test "only the root crumb carries an icon" do
    [_root | rest] = BoardCrumbs.flows(@board)
    refute Enum.any?(rest, &Map.has_key?(&1, :icon))
  end
end
