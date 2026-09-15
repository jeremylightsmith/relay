defmodule RelayWeb.BoardLiveEscalationTest do
  @moduledoc """
  RE253 — a `needs_input` park raised by the ENGINE (a node failed and the flow's
  `--on failed --> needs_input` edge escalated it, failure mode A4) must be answerable. Before this
  card the drawer swapped the answer form for a red "⊗ AGENT STOPPED" banner with no input field,
  so every escalation was a dead end.

  RE279 — the answer surface renders exactly once, on the Detail tab; the Run tab's parked banner
  (and its `run-needs-input-*` copy) is gone, and the blocked strip above the tabs names the park.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Activity
  alias Relay.Cards
  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeJob

  setup :register_and_log_in_user

  setup %{user: user} do
    FakeDispatcher.register(self())
    board = Relay.Boards.get_or_create_default_board(user)
    flow = park_flow(board)
    start_engine!()
    %{board: board, flow: flow}
  end

  # A flow whose failed edge parks on needs_input (RLY-194 shape): a reported :failed makes an
  # escalation park; a reported :needs_input makes a genuine question.
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

  # Returns {card, run}; the run id is captured so the click assertion needs no ref re-resolution.
  defp park(board, flow, title, outcome, detail) do
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Cards.create_card(stage, %{title: title})
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{} = job}
    {:ok, _run} = Runs.report_outcome(job, %{outcome: outcome, detail: detail, session_id: "s"})
    {card, run}
  end

  defp open(conn, board, card) do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}")
    render_async(view)
    view
  end

  defp count(view, selector), do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()

  @guard "✗ commit guard: the working tree is dirty after `mix precommit`"

  test "an escalation park is answerable on Detail and shows the failure output", ctx do
    {card, _run} = park(ctx.board, ctx.flow, "Commit guard", :failed, @guard)
    view = open(ctx.conn, ctx.board, card)

    assert has_element?(view, "#card-drawer-tab-panel-detail #needs-input-panel", "NODE FAILED · YOUR CALL")
    assert has_element?(view, "#needs-input-panel", "brainstorm")
    assert has_element?(view, "#needs-input-failure-detail", "commit guard")
    assert has_element?(view, "#needs-input-answer")
    assert has_element?(view, "#needs-input-send")
    assert has_element?(view, "#needs-input-retry")

    # the dead end is gone
    refute has_element?(view, "#run-stopped-banner")
    refute has_element?(view, "#run-restart")
    refute render(view) =~ "AGENT STOPPED"
  end

  test "a parked escalation opens on Detail; the Run tab keeps its readout without duplicating the answer surface (RE279, RE325)",
       ctx do
    {card, _run} = park(ctx.board, ctx.flow, "Commit guard", :failed, @guard)
    view = open(ctx.conn, ctx.board, card)

    # RE325 — a blocked card opens on Detail, where the escalation panel lives
    assert has_element?(view, "#card-drawer-tab-detail[data-active='true']")
    refute has_element?(view, "#card-drawer-tab-panel-detail.hidden")
    assert has_element?(view, "#card-drawer-tab-panel-detail #needs-input-panel", "NODE FAILED · YOUR CALL")

    # the Run tab is one click away and keeps its status readout
    view |> element("#card-drawer-tab-run") |> render_click()
    refute has_element?(view, "#card-drawer-tab-panel-run.hidden")
    assert has_element?(view, "#card-drawer-tab-panel-run", "Parked — waiting on your answer")

    refute has_element?(view, ".run-banner-parked")
    refute has_element?(view, "#run-needs-input-panel")
    assert count(view, "#needs-input-panel") == 1
    assert count(view, "#needs-input-retry") == 1
  end

  test "answering an escalation park unblocks the card and records the note", ctx do
    {card, _run} = park(ctx.board, ctx.flow, "Commit guard", :failed, @guard)
    view = open(ctx.conn, ctx.board, card)

    view
    |> form("#needs-input-form", answer: %{body: "try running the formatter first"})
    |> render_submit()

    reloaded = Cards.get_card(ctx.board, card.id)
    refute reloaded.status == :needs_input
    assert Enum.any?(Activity.list_conversation(reloaded), &(&1.body =~ "formatter"))
    refute has_element?(view, "#card-drawer-blocked-strip")
  end

  test "clicking Retry revives the run in place and clears the card's block", ctx do
    {card, run} = park(ctx.board, ctx.flow, "Commit guard", :failed, @guard)
    view = open(ctx.conn, ctx.board, card)

    view |> element("#needs-input-retry") |> render_click()

    assert Runs.get_run!(run.id).status == :running
    assert Cards.get_card(ctx.board, card.id).status == :working
    assert_receive {:dispatched, %NodeJob{node_key: "brainstorm"}}
  end

  # `park_kind/1` returns nil for any park that is neither A1 nor A4 — reachable when the agent
  # calls `relay needs-input` (card blocks, run parks :needs_input) and the runner then dies
  # before reporting, so the reaper re-parks the run :runner_gone. The card is still
  # :needs_input, so the drawer still renders the panel; every call site must degrade that nil to
  # the question face rather than pass nil through.
  test "a park neither A1 nor A4 degrades to the question face in the panel and the strip", ctx do
    {card, run} = park(ctx.board, ctx.flow, "Runner died", :needs_input, "Which auth model?")

    run
    |> Ecto.Changeset.change(parked_reason: :runner_gone)
    |> Relay.Repo.update!()

    assert is_nil(Runs.park_kind(Runs.get_run!(run.id)))

    view = open(ctx.conn, ctx.board, card)

    assert has_element?(view, "#needs-input-panel", "RELAY AI NEEDS YOUR INPUT")
    assert has_element?(view, "#card-drawer-blocked-strip-eyebrow", "BRAINSTORM ASKED AND EXITED")
    refute has_element?(view, ".run-banner-parked")
    refute render(view) =~ "NODE FAILED"
  end

  test "a genuine question keeps today's face, with no Retry and no escalation copy", ctx do
    {card, _run} = park(ctx.board, ctx.flow, "Real question", :needs_input, "Which auth model?")
    view = open(ctx.conn, ctx.board, card)

    assert has_element?(view, "#needs-input-panel", "RELAY AI NEEDS YOUR INPUT")
    assert has_element?(view, "#needs-input-question", "Which auth model?")
    refute has_element?(view, "#needs-input-retry")
    refute has_element?(view, "#needs-input-failure-detail")
    refute render(view) =~ "NODE FAILED"
  end

  test "the blocked strip names an escalation as the node that failed (RE279)", ctx do
    {card, _run} = park(ctx.board, ctx.flow, "Commit guard", :failed, @guard)
    view = open(ctx.conn, ctx.board, card)

    assert has_element?(view, "#card-drawer-blocked-strip-eyebrow", "BRAINSTORM FAILED — YOUR CALL")
  end

  test "the blocked strip names a genuine question as the node that asked and exited (RE279)", ctx do
    {card, _run} = park(ctx.board, ctx.flow, "Real question", :needs_input, "Which auth model?")
    view = open(ctx.conn, ctx.board, card)

    assert has_element?(view, "#card-drawer-blocked-strip-eyebrow", "BRAINSTORM ASKED AND EXITED")
    assert has_element?(view, "#card-drawer-blocked-strip-question", "Which auth model?")
  end
end
