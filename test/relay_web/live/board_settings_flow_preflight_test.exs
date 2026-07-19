defmodule RelayWeb.BoardSettingsFlowPreflightTest do
  @moduledoc """
  The enable confirm's readiness list (RLY-182). Asserts on the per-check element ids, not on
  prose, per AGENTS.md. The CTA must stay clickable in EVERY state — this feature reports, it
  never blocks.
  """
  use RelayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Flows
  alias Relay.Runs.Capacity

  setup :register_and_log_in_user

  setup %{user: user} do
    start_supervised!(Relay.Runs.Supervisor)
    board = Boards.get_or_create_default_board(user)
    %{board: board}
  end

  defp open_confirm(conn, board, key) do
    flow = Flows.get_flow!(board, key)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=flows")
    view |> element("#flow-#{flow.id}-toggle") |> render_click()
    {view, flow}
  end

  # Named connect_executor/2, not connect/2 — RelayWeb.ConnCase imports
  # Phoenix.ConnTest.connect/2, and a same-arity local def conflicts with it.
  defp connect_executor(board, opts) do
    executor =
      insert(:executor,
        board: board,
        name: opts[:name] || "mac-1",
        capabilities: opts[:capabilities],
        last_heartbeat: opts[:last_heartbeat] || DateTime.truncate(DateTime.utc_now(), :second)
      )

    Capacity.put(executor.id, opts[:capacity] || %{shared_clean: 1, exclusive: 1})
    executor
  end

  test "with no runner connected the executor check fails and the CTA still works",
       %{conn: conn, board: board} do
    {view, flow} = open_confirm(conn, board, "plan")

    assert has_element?(view, "#flow-#{flow.id}-preflight")
    assert has_element?(view, "#flow-#{flow.id}-preflight-executor.preflight-warn")
    assert has_element?(view, "#flow-#{flow.id}-confirm-cta")

    # The Plan flow requires the write-plan skill — with no runner connected, that can't be
    # checked, so the skills row must read as unresolved rather than a false green.
    assert has_element?(view, "#flow-#{flow.id}-preflight-skills.preflight-warn")
    refute has_element?(view, "#flow-#{flow.id}-preflight-capacity")

    view |> element("#flow-#{flow.id}-confirm-cta") |> render_click()
    assert Flows.get_flow!(board, "plan").enabled
  end

  test "a runner silent long enough to be reaped reads as no runner connected, not a candidate",
       %{conn: conn, board: board} do
    gone_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-3600, :second)

    connect_executor(board,
      capabilities: %{"agents" => [], "skills" => ["write-plan"]},
      last_heartbeat: gone_at
    )

    {view, flow} = open_confirm(conn, board, "plan")

    assert has_element?(view, "#flow-#{flow.id}-preflight-executor.preflight-warn")
    assert has_element?(view, "#flow-#{flow.id}-preflight-skills.preflight-warn")
    refute has_element?(view, "#flow-#{flow.id}-preflight-unreported")
  end

  test "an exclusive flow with no exclusive capacity fails the capacity check",
       %{conn: conn, board: board} do
    connect_executor(board, capacity: %{shared_clean: 3, exclusive: 0}, capabilities: %{"agents" => [], "skills" => []})
    {view, flow} = open_confirm(conn, board, "code")

    assert has_element?(view, "#flow-#{flow.id}-preflight-capacity.preflight-warn")
    assert render(view) =~ "exclusive"
  end

  test "a missing agent is named in the agents check", %{conn: conn, board: board} do
    connect_executor(board,
      capacity: %{shared_clean: 1, exclusive: 1},
      capabilities: %{"agents" => ["plan-implementer"], "skills" => []}
    )

    {view, flow} = open_confirm(conn, board, "code")

    assert has_element?(view, "#flow-#{flow.id}-preflight-agents.preflight-warn")
    assert render(view) =~ "smoke-tester"
  end

  test "a fully-satisfied flow passes every check with nothing missing",
       %{conn: conn, board: board} do
    connect_executor(board, capabilities: %{"agents" => [], "skills" => ["write-plan"]})
    {view, flow} = open_confirm(conn, board, "plan")

    for check <- ~w(stages executor capacity agents skills) do
      assert has_element?(view, "#flow-#{flow.id}-preflight-#{check}.preflight-ok")
    end

    refute has_element?(view, "#flow-#{flow.id}-preflight-unreported")
  end

  test "an executor that never reported gets a caveat, not a missing-agents alarm",
       %{conn: conn, board: board} do
    connect_executor(board, capabilities: nil)
    {view, flow} = open_confirm(conn, board, "code")

    assert has_element?(view, "#flow-#{flow.id}-preflight-unreported")
    assert has_element?(view, "#flow-#{flow.id}-preflight-agents.preflight-ok")
  end

  test "the disable confirm shows no preflight at all", %{conn: conn, board: board} do
    {:ok, _flow} = board |> Flows.get_flow!("plan") |> Flows.enable_flow()
    {view, flow} = open_confirm(conn, board, "plan")

    refute has_element?(view, "#flow-#{flow.id}-preflight")
    assert has_element?(view, "#flow-#{flow.id}-confirm-cta")
  end

  test "the stale engine note is gone", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=flows")
    refute has_element?(view, "#flows-engine-note")
  end
end
