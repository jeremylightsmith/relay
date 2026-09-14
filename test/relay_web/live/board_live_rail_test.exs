defmodule RelayWeb.BoardLiveRailTest do
  @moduledoc "RE282 — the drawer rail's Flow row and unused-fields group, driven through BoardLive."
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Flows
  alias Relay.Runs

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
    code = Enum.find(board.stages, &(&1.name == "Code"))
    %{board: board, backlog: backlog, code: code}
  end

  defp open(conn, board, ref) do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
    render_async(view)
    view
  end

  defp flow_text(flow), do: flow |> Runs.happy_path() |> Enum.join(" → ")

  describe "Flow row" do
    test "shows the latest run's flow happy path", ctx do
      {:ok, card} = Cards.create_card(ctx.code, %{title: "Ran once"})

      insert(:run,
        card: card,
        flow_key: "spec",
        status: :failed,
        current_node: nil,
        finished_at: DateTime.utc_now()
      )

      view = open(ctx.conn, ctx.board, Cards.ref(ctx.board, card))

      expected = flow_text(Flows.get_flow!(ctx.board, "spec"))
      assert expected != ""
      assert has_element?(view, "#card-drawer-rail .rail-flow", expected)
    end

    test "falls back to the enabled flow queued to pick the card up", ctx do
      flow = Flows.get_flow!(ctx.board, "code")
      {:ok, flow} = Flows.enable_flow(flow)
      stage = Enum.find(ctx.board.stages, &(&1.id == flow.pulls_from_stage_id))
      {:ok, card} = Cards.create_card(stage, %{title: "Waiting"})
      {:ok, card} = Cards.assign_ai(card)

      view = open(ctx.conn, ctx.board, Cards.ref(ctx.board, card))

      assert has_element?(view, "#card-drawer-rail .rail-flow", flow_text(flow))
    end

    test "is absent for a card with no runs and no queued flow", ctx do
      {:ok, card} = Cards.create_card(ctx.backlog, %{title: "Just an idea"})

      view = open(ctx.conn, ctx.board, Cards.ref(ctx.board, card))

      refute has_element?(view, "#card-drawer-rail .rail-flow")
    end
  end
end
