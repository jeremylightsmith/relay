defmodule HamacaWeb.Browser.BoardDropExpandTest do
  @moduledoc """
  Real-browser (Playwright) tests for RE506: dragging a card onto a collapsed stage or sub-lane
  strip expands that lane, with the card visible.

  The server only reveals a collapsed drop target when the `move_card` payload carries
  `drag: true`, which the `BoardDnD` hook (`assets/js/hooks/board_dnd.js`) sends on a drop.
  `Phoenix.LiveViewTest` never runs JS hooks, so only a real browser proves the flag travels end
  to end. The drawer's Move to… menu sends no such flag and must leave the strip collapsed.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias Hamaca.Accounts
  alias Hamaca.Boards
  alias Hamaca.Cards

  @moduletag :playwright

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    plan = Enum.find(board.stages, &(&1.name == "Plan"))

    %{user: user, board: board, code: code, plan: plan}
  end

  test "dragging a card onto a collapsed stage strip expands the stage with the card in it", ctx do
    {:ok, code} = Boards.update_stage(ctx.code, %{collapsed_by_default: true})
    {:ok, _held} = Cards.create_card(code, %{title: "Held"})
    moved = card_ref(ctx.board, ctx.plan, "Incoming")

    ctx.conn
    |> visit_board("/board/#{ctx.board.slug}")
    |> assert_has("#stage-strip-#{code.id}")
    |> drag(board_card(moved), to: "#stage-strip-#{code.id}")
    |> refute_has("#stage-strip-#{code.id}")
    |> assert_has(in_stage(code.id, moved))
  end

  test "dragging a card onto a collapsed sub-lane strip expands the sub-lane with the card in it", ctx do
    {:ok, review} = Boards.enable_lane(ctx.code, :review)
    {:ok, waiting} = Cards.create_card(ctx.code, %{title: "Waiting"})
    {:ok, _waiting} = Cards.move_card(waiting, review, 0)
    moved = card_ref(ctx.board, ctx.plan, "Incoming")

    ctx.conn
    |> visit_board("/board/#{ctx.board.slug}")
    |> click("#sublane-#{review.id}-header")
    |> assert_has("#sublane-#{review.id}-strip")
    |> drag(board_card(moved), to: "#sublane-#{review.id}-strip")
    |> refute_has("#sublane-#{review.id}-strip")
    |> assert_has("#sublane-#{review.id}-cards #{board_card(moved)}")
  end

  test "moving a card into a collapsed stage with the drawer's Move to… leaves it a strip", ctx do
    {:ok, code} = Boards.update_stage(ctx.code, %{collapsed_by_default: true})
    {:ok, _held} = Cards.create_card(code, %{title: "Held"})
    moved = card_ref(ctx.board, ctx.plan, "Incoming")

    ctx.conn
    |> visit_board("/board/#{ctx.board.slug}")
    |> assert_has("#stage-strip-#{code.id} .stage-count", text: "1", exact: true)
    |> click(board_card(moved))
    |> assert_has("#card-drawer .drawer-card-ref", text: moved, exact: true)
    |> click("#card-drawer-stage-chip")
    |> click("#card-drawer-move-to-#{code.id}")
    |> assert_has("#stage-strip-#{code.id} .stage-count", text: "2", exact: true)
    |> assert_has("#stage-strip-#{code.id}")
  end

  defp card_ref(board, stage, title) do
    {:ok, card} = Cards.create_card(stage, %{title: title})
    Cards.ref(board, card)
  end

  defp visit_board(conn, path) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit(path)
    # A push from a hook that hasn't mounted yet is lost, so wait for THIS page's socket.
    |> assert_has("body .phx-connected")
  end

  defp board_card(ref), do: ~s(.board-card[data-ref="#{ref}"])

  defp in_stage(stage_id, ref), do: ~s(.stage-column[data-stage-id="#{stage_id}"] #{board_card(ref)})
end
