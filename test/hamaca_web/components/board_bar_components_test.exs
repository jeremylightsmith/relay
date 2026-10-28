defmodule HamacaWeb.BoardBarComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HamacaWeb.BoardBarComponents

  # RE497: the board bar's building blocks, rendered in isolation. The markup contract comes
  # from the card mockups "B — one row: board name opens the switcher, ⋯ holds views" and
  # "Wide B — the phone's ⋯ on desktop too".

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  describe "board_more_menu/1" do
    @unfinished_setup %{finished?: false, position: 3, total: 7, closed?: false}

    defp more_menu(overrides) do
      assigns =
        Map.merge(
          %{
            board_slug: "acme",
            active_view: :board,
            show_logs: true,
            logs_open: false,
            settings_path: "/board/acme/settings",
            setup: @unfinished_setup
          },
          Map.new(overrides)
        )

      (&BoardBarComponents.board_more_menu/1)
      |> render_component(assigns)
      |> LazyHTML.from_fragment()
    end

    test "phones get the View section, the active view marked current" do
      doc = more_menu(%{})

      assert count(doc, ~s(li.sm\\:hidden a#board-more-view-board[aria-current="page"])) == 1
      assert count(doc, ~s(li.sm\\:hidden a#board-more-view-story-map[href="/board/acme/story-map"])) == 1
      assert count(doc, "li.sm\\:hidden a#board-more-view-value-stream") == 1
      assert count(doc, "#board-more-view-story-map[aria-current]") == 0
    end

    test "the wide-only Agent log item is unpressed while the logs are closed" do
      doc = more_menu(%{})

      assert count(doc, ~s(li.hidden.sm\\:flex button#board-more-agent-log[aria-pressed="false"])) == 1
    end

    test "Board settings links to settings_path" do
      assert count(more_menu(%{}), ~s(a#board-more-settings[href="/board/acme/settings"])) == 1
    end

    test "Setup carries the setup chip and the button grows the primary dot" do
      doc = more_menu(%{})

      assert doc |> LazyHTML.query("#board-more-setup") |> LazyHTML.text() =~ "Setup · 3 of 7"
      assert count(doc, "#board-more-button #board-more-dot.bg-primary") == 1
    end

    test "with no setup, no logs and no settings path only the view links remain" do
      doc = more_menu(%{setup: nil, show_logs: false, settings_path: nil})

      assert count(doc, "#board-more-setup") == 0
      assert count(doc, "#board-more-dot") == 0
      assert count(doc, "#board-more-agent-log") == 0
      assert count(doc, "#board-more-settings") == 0

      for key <- ~w(board story-map value-stream) do
        assert count(doc, "#board-more-view-#{key}") == 1
      end
    end

    test "open logs press the Agent log item and check it" do
      doc = more_menu(%{show_logs: true, logs_open: true})

      assert count(doc, ~s(#board-more-agent-log[aria-pressed="true"])) == 1
      assert count(doc, "#board-more-agent-log .hero-check") == 1
    end

    test "a finished setup reads done and still shows the dot" do
      doc = more_menu(%{setup: %{finished?: true, closed?: false, position: 7, total: 7}})

      assert doc |> LazyHTML.query("#board-more-setup") |> LazyHTML.text() =~ "Setup · done"
      assert count(doc, "#board-more-dot") == 1
    end

    test "the menu starts hidden and toggles client-side from the ⋯ button" do
      doc = more_menu(%{})

      assert count(doc, ~s(ul#board-more-menu.hidden[role="menu"])) == 1
      [click] = doc |> LazyHTML.query("#board-more-button") |> LazyHTML.attribute("phx-click")
      assert click =~ "#board-more-menu"
      assert count(doc, "#board-more[phx-click-away]") == 1
    end
  end

  describe "board_switcher_menu/1" do
    defp switcher_menu(assigns) do
      (&BoardBarComponents.board_switcher_menu/1)
      |> render_component(assigns)
      |> LazyHTML.from_fragment()
    end

    test "before the summaries load it shows only All boards, hidden" do
      doc = switcher_menu(%{board: %{slug: "acme", name: "Acme"}, boards: nil})

      assert count(doc, "#board-switcher-menu.hidden") == 1

      all = LazyHTML.query(doc, ~s(a#board-switcher-all-boards[href="/boards"]))
      assert LazyHTML.text(all) =~ "All boards"

      assert count(doc, "[id^=board-switcher-row-]") == 0
      refute LazyHTML.text(doc) =~ "Switch board"
    end

    test "loaded rows mark the current board and carry star, AI dot and needs-you badge" do
      boards = [
        %{slug: "acme", key: "AC", name: "Acme", starred?: true, ai_active?: true, needs_you_count: 3},
        %{slug: "beta", key: "BE", name: "Beta", starred?: false, ai_active?: false, needs_you_count: 0}
      ]

      doc = switcher_menu(%{board: %{slug: "acme", name: "Acme"}, boards: boards})

      assert LazyHTML.text(doc) =~ "Switch board"

      acme = LazyHTML.query(doc, "#board-switcher-row-acme")
      assert LazyHTML.attribute(acme, "aria-current") == ["page"]
      assert count(acme, ".hero-star-solid") == 1
      assert count(acme, ".bg-secondary") == 1
      assert acme |> LazyHTML.query(".badge-primary") |> LazyHTML.text() |> String.trim() == "3"
      assert count(acme, ".hero-check") == 1

      beta = LazyHTML.query(doc, ~s(#board-switcher-row-beta[href="/board/beta"]))
      assert Enum.count(beta) == 1
      assert count(doc, "#board-switcher-row-beta[aria-current]") == 0
      assert count(beta, ".hero-star-solid") == 0
      assert count(beta, ".bg-secondary") == 0
      assert count(beta, ".badge-primary") == 0
      assert count(beta, ".hero-check") == 0

      assert doc |> LazyHTML.query("[id^=board-switcher-row-]") |> LazyHTML.attribute("id") == [
               "board-switcher-row-acme",
               "board-switcher-row-beta"
             ]
    end

    test "the open attr (storybook) drops hidden" do
      doc = switcher_menu(%{board: %{slug: "acme", name: "Acme"}, open: true})

      assert count(doc, "#board-switcher-menu") == 1
      assert count(doc, "#board-switcher-menu.hidden") == 0
    end
  end
end
