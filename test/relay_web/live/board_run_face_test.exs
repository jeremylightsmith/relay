defmodule RelayWeb.BoardRunFaceTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Flows
  alias Relay.Runs

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    %{board: board, code: code}
  end

  defp ai_card(stage, title, status) do
    {:ok, card} = Cards.create_card(stage, %{title: title})
    {:ok, card} = Cards.assign_ai(card)
    {:ok, card} = Cards.set_status(card, %{status: status})
    card
  end

  test "an active run's face replaces the legacy strip and updates on run_changed",
       %{conn: conn, board: board, code: code} do
    card = ai_card(code, "Mid flight", :working)
    run = insert(:run, card: card, current_node: "implement")
    insert(:node_execution, run: run, node: "branch")
    ref = Cards.ref(board, card)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    render_async(view)

    assert has_element?(view, "#card-#{ref}-run-face")
    assert has_element?(view, "[data-ref='#{ref}'].border-l-secondary")
    refute has_element?(view, "#card-#{ref}-log-strip")

    run |> Ecto.Changeset.change(status: :failed, current_node: "quality_review") |> Relay.Repo.update!()
    Runs.broadcast_run_changed(board.id, card.id)

    assert has_element?(view, "#card-#{ref}-run-face", "RUN FAILED")
    assert has_element?(view, "[data-ref='#{ref}'].border-l-error")
  end

  test "a failed run's tile names the node it died on after close_run!/3",
       %{conn: conn, board: board, code: code} do
    card = ai_card(code, "Died mid flight", :working)
    run = insert(:run, card: card, current_node: "quality_review")
    insert(:node_execution, run: run, node: "implement")
    insert(:node_execution, run: run, node: "quality_review", outcome: :failed)
    ref = Cards.ref(board, card)

    closed = Runs.close_run!(run, :failed, "boom")
    assert is_nil(closed.current_node)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    render_async(view)

    assert has_element?(view, "#card-#{ref}-run-face", "RUN FAILED")
    assert has_element?(view, "#card-#{ref}-run-face", "stuck at quality_review")
  end

  test "a cancelled run's tile names the node it stopped at",
       %{conn: conn, board: board, code: code} do
    card = ai_card(code, "Cancelled mid flight", :working)
    run = insert(:run, card: card, current_node: "implement")
    insert(:node_execution, run: run, node: "branch")
    insert(:node_execution, run: run, node: "implement", outcome: nil, duration_s: nil)
    ref = Cards.ref(board, card)

    closed = Runs.close_run!(run, :cancelled, nil)
    assert is_nil(closed.current_node)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    render_async(view)

    assert has_element?(view, "#card-#{ref}-run-face", "CANCELLED")
    assert has_element?(view, "#card-#{ref}-run-face", "stopped at implement")
  end

  test "a queued card face names the flow", %{conn: conn, board: board} do
    flow = Flows.get_flow!(board, "code")
    {:ok, flow} = Flows.enable_flow(flow)
    stage = Enum.find(board.stages, &(&1.id == flow.pulls_from_stage_id))
    {:ok, card} = Cards.create_card(stage, %{title: "Waiting"})
    {:ok, card} = Cards.assign_ai(card)
    ref = Cards.ref(board, card)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    render_async(view)

    assert has_element?(view, "#card-#{ref}-run-face", "QUEUED · CODE FLOW")
  end

  test "a card that moved on after a terminal run falls back to legacy rendering",
       %{conn: conn, board: board} do
    flow = Flows.get_flow!(board, "code")
    backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
    true = backlog.id not in [flow.pulls_from_stage_id, flow.works_in_stage_id, flow.lands_on_stage_id]
    {:ok, card} = Cards.create_card(backlog, %{title: "Moved on"})
    insert(:run, card: card, status: :done, current_node: nil, finished_at: DateTime.utc_now())
    ref = Cards.ref(board, card)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    render_async(view)

    refute has_element?(view, "#card-#{ref}-run-face")
  end
end
