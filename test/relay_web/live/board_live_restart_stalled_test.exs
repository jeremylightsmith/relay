defmodule RelayWeb.BoardLiveRestartStalledTest do
  use RelayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Relay.Cards
  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeJob

  setup :register_and_log_in_user

  setup %{user: user} do
    FakeDispatcher.register(self())
    board = Relay.Boards.get_or_create_default_board(user)
    flow = park_flow(board)
    start_supervised!(Relay.Runs.Supervisor)
    %{board: board, flow: flow}
  end

  defp park_flow(board) do
    next_up = Enum.find(board.stages, &(&1.name == "Next up"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    review = Enum.find(board.stages, &(&1.name == "Spec:Review"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "park-flow",
        isolation: :shared_clean,
        pulls_from_stage_id: next_up.id,
        works_in_stage_id: spec.id,
        lands_on_stage_id: review.id,
        nodes: [%{key: "brainstorm", type: :agent, run: "/brainstorm {ref}"}],
        edges: [
          %{from: "start", to: "brainstorm"},
          %{from: "brainstorm", to: "done", on: :succeeded},
          %{from: "brainstorm", to: "needs_input", on: :failed}
        ]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  # Runs a card through the park flow and reports `outcome`, returning both the card (for
  # refs and DOM ids) and the resulting run (for status assertions).
  defp park(board, flow, title, outcome) do
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Cards.create_card(stage, %{title: title})
    {:ok, _run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{} = job}
    {:ok, run} = Runs.report_outcome(job, %{outcome: outcome, detail: "x", session_id: "s"})
    %{card: card, run: run}
  end

  defp open_dialog(view) do
    view |> element("#restart-stalled-button") |> render_click()
    view
  end

  # A card whose run is pinned to an executor that never connected — `retry_run/2`
  # refuses via `check_retry_executor/2` -> `check_executor_live/2` with
  # `{:error, {:executor_unavailable, name}}` before it ever dispatches anything, so
  # this needs no FakeDispatcher round trip (mirrors test/relay/runs/retry_test.exs's
  # `exclusive_failed_run/2`, built straight from factories rather than through `park/4`).
  defp refused_restart_card(board, executor_name) do
    spec = Enum.find(board.stages, &(&1.name == "Spec"))

    flow =
      insert(:flow,
        board: board,
        isolation: :exclusive,
        enabled: true,
        nodes: [%{key: "brainstorm", type: :agent, run: "/brainstorm {ref}"}],
        edges: [%{from: "start", to: "brainstorm"}]
      )

    card = insert(:card, stage: spec, title: "Pinned dead")

    run =
      insert(:run,
        card: card,
        status: :failed,
        current_node: nil,
        flow_key: flow.key,
        flow_id: flow.id
      )

    execution = insert(:node_execution, run: run, node_key: "brainstorm", outcome: :failed)

    insert(:node_job,
      node_execution: execution,
      state: :done,
      executor_name: executor_name,
      payload: %{"isolation" => "exclusive"}
    )

    %{card: card, run: run}
  end

  test "the header control opens a dialog naming every stalled card", ctx do
    a = park(ctx.board, ctx.flow, "Died A", :failed)
    b = park(ctx.board, ctx.flow, "Died B", :failed)
    ask = park(ctx.board, ctx.flow, "Real question", :needs_input)

    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")

    assert has_element?(view, "#restart-stalled-button", "2")
    refute has_element?(view, "#stalled-modal")

    open_dialog(view)

    assert has_element?(view, "#stalled-modal")
    assert has_element?(view, "#stalled-row-#{a.card.id}", Cards.ref(ctx.board, a.card))
    assert has_element?(view, "#stalled-row-#{a.card.id}", "Died A")
    assert has_element?(view, "#stalled-row-#{a.card.id}", "Agent died at brainstorm")
    assert has_element?(view, "#stalled-row-#{b.card.id}", "Died B")
    refute has_element?(view, "#stalled-row-#{ask.card.id}")
  end

  test "opening the dialog restarts nothing", ctx do
    a = park(ctx.board, ctx.flow, "Died A", :failed)
    b = park(ctx.board, ctx.flow, "Died B", :failed)

    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")
    open_dialog(view)

    assert Runs.get_run!(a.run.id).status == :parked
    assert Runs.get_run!(b.run.id).status == :parked
    assert has_element?(view, "#restart-stalled-button", "2")

    view |> element("#stalled-modal-close") |> render_click()

    refute has_element?(view, "#stalled-modal")
    assert Runs.get_run!(a.run.id).status == :parked
    assert has_element?(view, "#restart-stalled-button", "2")
  end

  test "there is no browser confirm and no bulk Restart-all", ctx do
    _a = park(ctx.board, ctx.flow, "Died A", :failed)

    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")

    refute view |> element("#restart-stalled-button") |> render() =~ "data-confirm"

    open_dialog(view)

    refute render(view) =~ ~s(phx-click="restart_stalled")
  end

  test "a row's Restart revives only that card and drops it from the list", ctx do
    a = park(ctx.board, ctx.flow, "Died A", :failed)
    b = park(ctx.board, ctx.flow, "Died B", :failed)

    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")
    open_dialog(view)

    view |> element("#stalled-restart-#{a.card.id}") |> render_click()

    assert Runs.get_run!(a.run.id).status == :running
    assert Runs.get_run!(b.run.id).status == :parked
    refute has_element?(view, "#stalled-row-#{a.card.id}")
    assert has_element?(view, "#stalled-row-#{b.card.id}")
    assert has_element?(view, "#stalled-modal")
    assert has_element?(view, "#restart-stalled-button", "1")
  end

  test "restarting the last stalled card closes the dialog and hides the control", ctx do
    only = park(ctx.board, ctx.flow, "Only one", :failed)

    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")
    open_dialog(view)

    view |> element("#stalled-restart-#{only.card.id}") |> render_click()

    assert Runs.get_run!(only.run.id).status == :running
    refute has_element?(view, "#stalled-modal")
    refute has_element?(view, "#restart-stalled-button")
  end

  test "clicking a row closes the dialog and opens that card's drawer", ctx do
    a = park(ctx.board, ctx.flow, "Died A", :failed)

    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")
    open_dialog(view)

    view |> element("#open-stalled-card-#{a.card.id}") |> render_click()

    assert_patch(view, ~p"/board/#{ctx.board.slug}?card=#{Cards.ref(ctx.board, a.card)}")
    refute has_element?(view, "#stalled-modal")
    assert has_element?(view, "#card-drawer")
  end

  test "a refused restart explains why inside the modal, not just as a toast", ctx do
    refused = refused_restart_card(ctx.board, "mac-never-connected")

    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")
    open_dialog(view)

    view |> element("#stalled-restart-#{refused.card.id}") |> render_click()

    assert Runs.get_run!(refused.run.id).status == :failed
    assert has_element?(view, "#stalled-modal")
    assert has_element?(view, "#stalled-modal", "mac-never-connected")
    assert has_element?(view, "#stalled-row-#{refused.card.id}")
  end

  test "the dialog reuses the archived-modal shell", ctx do
    _a = park(ctx.board, ctx.flow, "Died A", :failed)

    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")
    open_dialog(view)

    assert has_element?(view, "#stalled-modal.modal.modal-open[role=dialog]")
    assert has_element?(view, "#stalled-modal .modal-box.max-w-2xl")
    assert has_element?(view, "#stalled-list.divide-y.divide-base-200")
    assert has_element?(view, "#stalled-modal .font-mono.text-xs")
    assert has_element?(view, "#stalled-modal label.modal-backdrop")
  end

  test "the control is hidden when nothing is stalled", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")
    refute has_element?(view, "#restart-stalled-button")
    refute has_element?(view, "#stalled-modal")
  end
end
