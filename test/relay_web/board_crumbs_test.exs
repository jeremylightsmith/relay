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

  test "flows/2 ends on the Stages crumb, deep-linked to the flow's stage row" do
    assert [
             %{id: "top-bar-crumb-boards"},
             %{id: "top-bar-crumb-board"},
             %{id: "top-bar-crumb-settings"},
             %{
               id: "top-bar-crumb-stages",
               label: "Stages",
               to: "/board/payments/settings?section=stages#stage-7-row"
             }
           ] = BoardCrumbs.flows(@board, %{stage_id: 7})

    assert "Stages" == BoardSettingsLive.section_label(:stages)
  end

  test "only the root crumb carries an icon" do
    [_root | rest] = BoardCrumbs.flows(@board, %{stage_id: 7})
    refute Enum.any?(rest, &Map.has_key?(&1, :icon))
  end

  test "card_mockups/3 is Boards / <board> / <card title>, the card crumb a patch back to the drawer" do
    card = %{title: "Notif"}

    assert [
             %{id: "top-bar-crumb-boards"},
             %{id: "top-bar-crumb-board", to: "/board/payments"},
             %{id: "top-bar-crumb-card", label: "Notif", to: "/board/payments?card=PA1", patch: true}
           ] = BoardCrumbs.card_mockups(@board, card, "/board/payments?card=PA1")
  end
end
