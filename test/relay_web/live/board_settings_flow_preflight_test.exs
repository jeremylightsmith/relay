defmodule RelayWeb.BoardSettingsFlowPreflightTest do
  @moduledoc """
  The readiness report shown after turning a flow on from its stage row's band (RLY-182, RE431).
  Asserts on the per-check element ids, not on prose, per AGENTS.md. The toggle flips directly —
  this feature reports, it never blocks — and the list opens only when some check warns.
  """

  # async: false — start_engine!/1's Listener subscribes to the global `Relay.Events` firehose
  # (there is no per-instance topic), so under async every concurrent test's card event reaches
  # this test's private Listener, which reconciles on THIS test's sandbox connection and can steal
  # or contend the checkout mid-test (ADR 0009's Rule 2 fix is per-instance *naming*, not a
  # per-instance *firehose* — that gap is still open). This test never exercises reconciliation,
  # only the Registry-backed preflight path, so it does not need a Listener at all; revisit once
  # `start_engine!/1` can start a tree without one, or the firehose is scoped per instance.
  use RelayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Flows
  alias Relay.Runs.Capacity

  setup :register_and_log_in_user

  setup %{user: user} do
    start_engine!()
    board = Boards.get_or_create_default_board(user)
    %{board: board}
  end

  defp toggle(conn, board, key) do
    flow = Flows.get_flow!(board, key)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=stages")
    view |> element("#flow-#{flow.id}-toggle") |> render_click()
    {view, flow}
  end

  # Named connect_runner/2, not connect/2 — RelayWeb.ConnCase imports
  # Phoenix.ConnTest.connect/2, and a same-arity local def conflicts with it.
  defp connect_runner(board, opts) do
    runner =
      insert(:runner,
        board: board,
        name: opts[:name] || "mac-1",
        capabilities: opts[:capabilities],
        last_heartbeat: opts[:last_heartbeat] || DateTime.truncate(DateTime.utc_now(), :second)
      )

    Capacity.put(runner.id, runner.board_id, opts[:capacity] || %{shared_clean: 1, exclusive: 1})
    runner
  end

  test "with no runner connected the flow turns on and the runner check warns",
       %{conn: conn, board: board} do
    {view, flow} = toggle(conn, board, "plan")

    assert Flows.get_flow!(board, "plan").enabled
    assert has_element?(view, "#flow-#{flow.id}-preflight")
    assert has_element?(view, "#flow-#{flow.id}-preflight-runner.preflight-warn")

    # The Plan flow requires the write-plan skill — with no runner connected, that can't be
    # checked, so the skills row must read as unresolved rather than a false green.
    assert has_element?(view, "#flow-#{flow.id}-preflight-skills.preflight-warn")
    refute has_element?(view, "#flow-#{flow.id}-preflight-capacity")
  end

  test "a runner silent long enough to be reaped reads as no runner connected, not a candidate",
       %{conn: conn, board: board} do
    gone_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-3600, :second)

    connect_runner(board,
      capabilities: %{"agents" => [], "skills" => ["write-plan"]},
      last_heartbeat: gone_at
    )

    {view, flow} = toggle(conn, board, "plan")

    assert has_element?(view, "#flow-#{flow.id}-preflight-runner.preflight-warn")
    assert has_element?(view, "#flow-#{flow.id}-preflight-skills.preflight-warn")
    refute has_element?(view, "#flow-#{flow.id}-preflight-unreported")
  end

  test "an exclusive flow with no exclusive capacity fails the capacity check",
       %{conn: conn, board: board} do
    connect_runner(board, capacity: %{shared_clean: 3, exclusive: 0}, capabilities: %{"agents" => [], "skills" => []})
    {view, flow} = toggle(conn, board, "code")

    assert has_element?(view, "#flow-#{flow.id}-preflight-capacity.preflight-warn")
    assert render(view) =~ "exclusive"
  end

  test "a missing agent is named in the agents check", %{conn: conn, board: board} do
    connect_runner(board,
      capacity: %{shared_clean: 1, exclusive: 1},
      capabilities: %{"agents" => ["plan-implementer"], "skills" => []}
    )

    {view, flow} = toggle(conn, board, "code")

    assert has_element?(view, "#flow-#{flow.id}-preflight-agents.preflight-warn")
    assert render(view) =~ "smoke-tester"
  end

  test "a fully-satisfied flow turns on with no readiness list at all",
       %{conn: conn, board: board} do
    connect_runner(board, capabilities: %{"agents" => [], "skills" => ["write-plan"]})
    {view, flow} = toggle(conn, board, "plan")

    assert Flows.get_flow!(board, "plan").enabled
    refute has_element?(view, "#flow-#{flow.id}-preflight")
  end

  test "a runner that never reported gets a caveat, not a missing-agents alarm",
       %{conn: conn, board: board} do
    connect_runner(board, capabilities: nil)
    {view, flow} = toggle(conn, board, "code")

    assert has_element?(view, "#flow-#{flow.id}-preflight-unreported")
    assert has_element?(view, "#flow-#{flow.id}-preflight-agents.preflight-ok")
  end

  test "turning a flow off shows no preflight at all", %{conn: conn, board: board} do
    {:ok, _flow} = board |> Flows.get_flow!("plan") |> Flows.enable_flow()
    {view, flow} = toggle(conn, board, "plan")

    refute Flows.get_flow!(board, "plan").enabled
    refute has_element?(view, "#flow-#{flow.id}-preflight")
  end

  test "Got it dismisses the readiness list", %{conn: conn, board: board} do
    {view, flow} = toggle(conn, board, "plan")
    assert has_element?(view, "#flow-#{flow.id}-preflight")

    view |> element("#flow-#{flow.id}-preflight-dismiss") |> render_click()
    refute has_element?(view, "#flow-#{flow.id}-preflight")
    assert Flows.get_flow!(board, "plan").enabled
  end
end
