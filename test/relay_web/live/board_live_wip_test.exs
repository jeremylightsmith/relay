defmodule RelayWeb.BoardLiveWipTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    %{board: board, spec: stage_named(board, "Spec"), code: stage_named(board, "Code")}
  end

  defp stage_named(board, name), do: Enum.find(board.stages, &(&1.name == name))

  defp create_cards(stage, count) do
    for n <- 1..count do
      {:ok, card} = Cards.create_card(stage, %{title: "Card #{n}"})
      card
    end
  end

  defp chip_style(view, selector) do
    [style] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("style")

    style
  end

  describe "the stage header WIP chip" do
    test "within the limit it renders the neutral mockup chip", %{conn: conn, code: code, user: user} do
      {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 3})
      create_cards(code, 2)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-col-5 .stage-wip", "wip 2/3")
      refute has_element?(view, "#stage-col-5 .stage-wip[data-over]")

      style = chip_style(view, "#stage-col-5 .stage-wip")
      assert style =~ "background:oklch(0.96 0.006 255)"
      assert style =~ "color:oklch(0.48 0.02 255)"
      assert style =~ "font-family:var(--font-mono)"
    end

    test "over the limit it flips to the rose treatment", %{conn: conn, code: code, user: user} do
      {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 3})
      create_cards(code, 4)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-col-5 .stage-wip[data-over]", "wip 4/3")

      style = chip_style(view, "#stage-col-5 .stage-wip")
      assert style =~ "background:oklch(0.96 0.03 15)"
      assert style =~ "color:oklch(0.55 0.16 15)"
    end

    test "no chip renders when wip_limit is nil", %{conn: conn, code: code, user: user} do
      create_cards(code, 2)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-col-5 .stage-count", "2")
      refute has_element?(view, ".stage-wip")
    end

    test "sub-lane cards count toward the parent's WIP total (chip + over-state)",
         %{conn: conn, code: code, user: user} do
      {:ok, done_lane} = Boards.enable_lane(code, :done)
      {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 2})
      [first, second, _third] = create_cards(code, 3)
      {:ok, _moved} = Cards.move_card(first, done_lane, 0)
      {:ok, _moved} = Cards.move_card(second, done_lane, 1)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      # 1 card left in Code's main lane + 2 in its Done sub-lane = 3, over the limit of 2.
      assert has_element?(view, "#stage-col-5 .stage-wip[data-over]", "wip 3/2")
      refute has_element?(view, "#sublane-#{done_lane.id} .stage-wip")
    end

    test "an empty limited stage collapses to the strip, which shows no chip",
         %{conn: conn, spec: spec, user: user} do
      {:ok, _stage} = Boards.update_stage(spec, %{wip_limit: 3})

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-strip-#{spec.id}")
      refute has_element?(view, "#stage-strip-#{spec.id} .stage-wip")
      refute has_element?(view, ".stage-wip")
    end

    test "clearing the limit hides the chip live via the stages_changed broadcast",
         %{conn: conn, board: board, code: code} do
      {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 3})
      create_cards(code, 2)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      assert has_element?(view, "#stage-col-5 .stage-wip", "wip 2/3")

      {:ok, _stage} = Boards.update_stage(Boards.get_stage(board, code.id), %{wip_limit: nil})

      render(view)
      refute has_element?(view, ".stage-wip")
    end
  end

  describe "the stage column WIP threshold coloring" do
    test "under the limit the border and chip stay neutral", %{conn: conn, code: code, user: user} do
      {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 3})
      create_cards(code, 2)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-col-5[data-wip=under]")
      assert chip_style(view, "#stage-col-5") =~ "border:1px solid var(--color-base-300)"
    end

    test "at the limit the border and chip text turn amber", %{conn: conn, code: code, user: user} do
      {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 2})
      create_cards(code, 2)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-col-5[data-wip=at]")
      assert chip_style(view, "#stage-col-5") =~ "border:1px solid var(--color-warning)"
      assert chip_style(view, "#stage-col-5 .stage-wip") =~ "color:oklch(0.52 0.13 65)"
    end

    test "over the limit the border and chip text turn red", %{conn: conn, code: code, user: user} do
      {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 2})
      create_cards(code, 3)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-col-5[data-wip=over]")
      assert chip_style(view, "#stage-col-5") =~ "border:1px solid var(--color-error)"
      assert chip_style(view, "#stage-col-5 .stage-wip") =~ "color:oklch(0.55 0.16 15)"
    end

    test "with no limit the border stays neutral and no chip renders", %{conn: conn, code: code, user: user} do
      create_cards(code, 2)

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-col-5[data-wip=none]")
      assert chip_style(view, "#stage-col-5") =~ "border:1px solid var(--color-base-300)"
      refute has_element?(view, ".stage-wip")
    end
  end
end
