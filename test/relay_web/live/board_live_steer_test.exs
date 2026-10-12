defmodule RelayWeb.BoardLiveSteerTest do
  @moduledoc """
  RE358 — Steer now in the card drawer (card mockup "A — Steer is a mode of the Notes composer"):
  the Note | ↪ Steer now toggle while an agent node runs, the blue Steer composer, the stopping
  strip, the STEER note with its "sending…" marker, then the "✓ Sent to <node>" receipt and the
  node's threaded reply.

  Synchronous on purpose: the engine's Listener reconciles the whole suite's event firehose over
  this test's one sandbox connection, and alongside a LiveView that contention timed its checkouts
  out under the async suite's load (noisy Listener crashes, though every test passed). Run alone,
  it has the connection to itself.
  """
  use RelayWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Relay.Cards
  alias Relay.Repo
  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.Comment
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.Run

  @steer "Fold the backfill into Task 3"
  @reply "Dropped the migration task — the backfill now runs in Task 3."
  @footer "Notes are card content, not chat — they go into every agent’s context."

  setup :register_and_log_in_user

  setup %{user: user} do
    start_engine!()
    FakeDispatcher.register(self())

    board = Relay.Boards.get_or_create_default_board(user)
    {:ok, flow} = board |> Relay.Flows.get_flow!("plan") |> Relay.Flows.enable_flow()

    {:ok, runner} =
      Runs.upsert_runner(board, %{
        "name" => "steer-live-runner",
        "capacity" => %{"shared_clean" => 2, "exclusive" => 1},
        "version" => Runs.min_runner_version()
      })

    %{board: board, flow: flow, runner: runner}
  end

  ## Helpers

  defp new_card(board, title) do
    stage = Enum.find(board.stages, &(&1.name == "Next up"))

    # write_plan declares it writes `plan` + `tasks` (RE244), so a card that goes on to report
    # `succeeded` must already carry both.
    {:ok, card} =
      Cards.create_card(stage, %{title: title, spec: "# Spec", acceptance_criteria: "1. It works.", plan: "# Plan"})

    insert(:sub_task, card: card, title: "Task 1")
    card
  end

  # A card whose plan run is :running on write_plan with the attempt-1 job claimed.
  defp running_card(ctx, opts \\ []) do
    card = new_card(ctx.board, "Steer the planner")
    {:ok, run} = Runs.start_run(card, ctx.flow)
    assert_receive {:dispatched, %NodeJob{}}
    claimed = claim!(ctx.runner)
    if session = opts[:session], do: set_session(claimed, session)
    %{card: card, run: run, job: claimed}
  end

  defp claim!(runner) do
    {:ok, %NodeJob{} = job} = Runs.claim_next_job(runner)
    job
  end

  defp set_session(%NodeJob{} = job, session_id) do
    NodeExecution
    |> Repo.get!(job.node_execution_id)
    |> Ecto.Changeset.change(session_id: session_id)
    |> Repo.update!()
  end

  defp open(conn, board, card, query) do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}" <> query)
    render_async(view)
    view
  end

  # The Run tab opens first for a running card (default_drawer_tab/2).
  defp open_detail(conn, board, card, query \\ "") do
    view = open(conn, board, card, query)
    view |> element("#card-drawer-tab-detail") |> render_click()
    view
  end

  # The run-event path: mark the card dirty, then flush now instead of waiting out the debounce.
  defp run_refresh(view, card) do
    send(view.pid, {:run_changed, card.id})
    send(view.pid, :flush_run_changes)
    render(view)
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp classes(view, selector) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute("class") |> List.first("") |> String.split()
  end

  defp text(view, selector), do: view |> doc() |> LazyHTML.query(selector) |> LazyHTML.text() |> squish()

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  defp steer_comment!(card), do: Repo.one!(from c in Comment, where: c.card_id == ^card.id and c.kind == :steer)

  defp steer!(view) do
    view |> element("#card-drawer-note-mode-steer") |> render_click()
    view |> form("#card-drawer-comment-form", comment: %{body: @steer}) |> render_submit()
  end

  # A flow agent_a → precommit (shell) → agent_b on the Spec stage (a stage holds one flow, so the
  # seeded spec flow is cleared first).
  defp shell_flow(board) do
    {:ok, _deleted} = Relay.Flows.delete_flow(Relay.Flows.get_flow!(board, "spec"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "shelly",
        isolation: :shared_clean,
        stage_id: spec.id,
        nodes: [
          %{key: "agent_a", type: :agent, run: "/a {ref}"},
          %{key: "precommit", type: :shell, run: "mix precommit"},
          %{key: "agent_b", type: :agent, run: "/b {ref}"}
        ],
        edges: [
          %{from: "start", to: "agent_a"},
          %{from: "agent_a", to: "precommit", on: :succeeded},
          %{from: "precommit", to: "agent_b", on: :succeeded},
          %{from: "agent_b", to: "done", on: :succeeded}
        ]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  # A card whose shell_flow/1 run sits on `precommit`, its job queued.
  defp shell_card(ctx) do
    card = new_card(ctx.board, "On the shell node")
    {:ok, run} = Runs.start_run(card, shell_flow(ctx.board))
    assert_receive {:dispatched, %NodeJob{}}
    {:ok, _run} = Runs.report_outcome(claim!(ctx.runner), %{outcome: :succeeded, detail: "a done"})
    assert_receive {:dispatched, %NodeJob{node_key: "precommit"} = precommit}
    assert Repo.get!(Run, run.id).current_node == "precommit"
    %{card: card, run: run, precommit: precommit}
  end

  ## Scenario 5 — the toggle while an agent node runs

  test "a running agent node offers Note | Steer now, on Note, with the next-step hint", ctx do
    %{card: card} = running_card(ctx)
    view = open_detail(ctx.conn, ctx.board, card)

    assert has_element?(view, "#card-drawer-note-mode")
    assert has_element?(view, ~s(#card-drawer-note-mode-note[data-active="true"]))
    assert has_element?(view, ~s(#card-drawer-note-mode-steer[data-active="false"]))
    assert text(view, "#card-drawer-note-hint") == "Reaches the agent at its next step. Switch to Steer now to interrupt."
    assert has_element?(view, "#card-drawer-note-hint b.text-primary", "Steer now")
    refute has_element?(view, "#card-drawer-notes", @footer)
  end

  ## Scenario 6 — nothing to steer

  describe "nothing to steer" do
    test "a card with no run keeps the plain composer and the footer", ctx do
      card = new_card(ctx.board, "No run")
      view = open_detail(ctx.conn, ctx.board, card)

      refute has_element?(view, "#card-drawer-note-mode")
      refute has_element?(view, "#card-drawer-note-hint")
      assert has_element?(view, "#card-drawer-notes", @footer)
    end

    test "a run parked on needs-input keeps the plain composer and the footer", ctx do
      %{card: card, run: run, job: job} = running_card(ctx)
      {:ok, _run} = Runs.report_outcome(job, %{outcome: :needs_input, detail: "which one?"})
      assert Repo.get!(Run, run.id).status == :parked

      view = open_detail(ctx.conn, ctx.board, card)

      refute has_element?(view, "#card-drawer-note-mode")
      refute has_element?(view, "#card-drawer-note-hint")
      assert has_element?(view, "#card-drawer-notes", @footer)
    end

    test "a run on a shell node keeps the plain composer and the footer", ctx do
      %{card: card} = shell_card(ctx)
      view = open_detail(ctx.conn, ctx.board, card)

      refute has_element?(view, "#card-drawer-note-mode")
      refute has_element?(view, "#card-drawer-note-hint")
      assert has_element?(view, "#card-drawer-notes", @footer)
    end
  end

  ## Scenario 7 — Steer mode's composer

  test "Steer mode turns the composer blue and says exactly what happens", ctx do
    %{card: card} = running_card(ctx)
    view = open_detail(ctx.conn, ctx.board, card)

    view |> element("#card-drawer-note-mode-steer") |> render_click()

    assert has_element?(view, ~s(#card-drawer-note-mode-steer[data-active="true"]))
    box = classes(view, "#card-drawer-note-images")
    assert "border-2" in box
    assert "border-primary/60" in box

    assert text(view, "#card-drawer-comment-submit .pending-idle") == "Steer now"
    submit = classes(view, "#card-drawer-comment-submit")
    for c <- ~w(btn btn-primary btn-sm), do: assert(c in submit, "submit lacks #{c}: #{inspect(submit)}")

    assert has_element?(view, ~s(#card-drawer-comment-input[placeholder="What should write_plan do differently?"]))
    assert text(view, "#card-drawer-note-hint") == "Stops write_plan and restarts it with this note — session kept."
    assert has_element?(view, "#card-drawer-note-hint code", "write_plan")
    assert "text-primary/80" in classes(view, "#card-drawer-note-hint")
  end

  ## Scenario 8 — sending a steer

  test "sending a steer shows the STEER note sending…, the stopping strip, and returns to Note", ctx do
    %{card: card, run: run} = running_card(ctx)
    view = open_detail(ctx.conn, ctx.board, card)

    steer!(view)

    comment = steer_comment!(card)
    assert comment.body == @steer
    entry = "#timeline-comment-#{comment.id}"
    assert text(view, "#{entry}-steer-tag") == "STEER"
    assert text(view, "#{entry}-sending") == "sending…"
    assert has_element?(view, "#{entry}-sending .loading-spinner")
    refute has_element?(view, "#{entry}-receipt")

    assert text(view, "#working-strip-stopping") =~ "Stopping write_plan… restarting with your steer"
    assert has_element?(view, "#working-strip-stopping", "≤ one heartbeat")
    refute has_element?(view, "#working-strip")

    assert has_element?(view, ~s(#card-drawer-note-mode-note[data-active="true"]))
    assert text(view, "#card-drawer-comment-submit .pending-idle") == "Add note"

    assert [stopped, _restarted] =
             Repo.all(from e in NodeExecution, where: e.run_id == ^run.id, order_by: [asc: e.id])

    assert stopped.outcome == :steered
    assert Repo.get!(Run, run.id).status == :running
  end

  ## Scenario 9 — the receipt once the restarted job is claimed

  test "the restarted job's claim turns sending… into ✓ Sent to write_plan, session kept", ctx do
    %{card: card} = running_card(ctx, session: "sess-1")
    view = open_detail(ctx.conn, ctx.board, card)
    steer!(view)
    comment = steer_comment!(card)

    _restarted = claim!(ctx.runner)
    run_refresh(view, card)

    refute has_element?(view, "#working-strip-stopping")
    assert text(view, "#working-strip-node") == "on write_plan"
    refute has_element?(view, "#timeline-comment-#{comment.id}-sending")
    assert text(view, "#timeline-comment-#{comment.id}-receipt") =~ "✓ Sent to write_plan"
    assert has_element?(view, "#timeline-comment-#{comment.id}-receipt", "· restarted, session kept")
  end

  test "a restart with no known session has no session-kept suffix", ctx do
    %{card: card} = running_card(ctx)
    view = open_detail(ctx.conn, ctx.board, card)
    steer!(view)
    comment = steer_comment!(card)

    _restarted = claim!(ctx.runner)
    run_refresh(view, card)

    assert text(view, "#timeline-comment-#{comment.id}-receipt") =~ "✓ Sent to write_plan"
    refute has_element?(view, "#timeline-comment-#{comment.id}-receipt", "session kept")
  end

  ## Scenario 10 — the threaded reply

  test "the restarted attempt's reply threads under the steer, and nowhere else", ctx do
    %{card: card} = running_card(ctx, session: "sess-1")
    view = open_detail(ctx.conn, ctx.board, card)
    steer!(view)
    comment = steer_comment!(card)
    restarted = claim!(ctx.runner)
    run_refresh(view, card)

    {:ok, _run} = Runs.report_outcome(restarted, %{outcome: :succeeded, detail: @reply})
    run_refresh(view, card)

    reply = "#timeline-comment-#{comment.id} #timeline-comment-#{comment.id}-receipt-reply"
    assert has_element?(view, reply, "write_plan")
    assert has_element?(view, reply, @reply)

    holders =
      view
      |> doc()
      |> LazyHTML.query("#card-drawer-conversation > li")
      |> Enum.filter(&(&1 |> LazyHTML.text() |> String.contains?(@reply)))

    assert Enum.map(holders, &LazyHTML.attribute(&1, "id")) == [["timeline-comment-#{comment.id}"]]
  end

  ## Scenario 11 — a steer degraded to a note

  test "a steer noted on a shell node is delivered by the next agent node's claim", ctx do
    %{card: card, precommit: precommit} = shell_card(ctx)
    view = open_detail(ctx.conn, ctx.board, card)

    {:ok, comment, :noted} = Runs.steer(card, {:user, ctx.user.id}, "use approach B", [])
    render(view)
    assert text(view, "#timeline-comment-#{comment.id}-steer-tag") == "STEER"
    assert has_element?(view, "#timeline-comment-#{comment.id}-sending")

    claimed = claim!(ctx.runner)
    assert claimed.id == precommit.id
    {:ok, _run} = Runs.report_outcome(claimed, %{outcome: :succeeded})
    assert_receive {:dispatched, %NodeJob{node_key: "agent_b"}}
    _agent_b = claim!(ctx.runner)
    run_refresh(view, card)

    assert text(view, "#timeline-comment-#{comment.id}-steer-tag") == "STEER"
    assert text(view, "#timeline-comment-#{comment.id}-receipt") =~ "✓ Sent to agent_b"
    refute has_element?(view, "#timeline-comment-#{comment.id}-receipt", "session kept")
    refute has_element?(view, "#timeline-comment-#{comment.id}-sending")
  end

  ## Scenario 13 — 390px and the native embed

  describe "mobile and the native embed" do
    test "the narrow-screen extras carry max-sm:hidden", ctx do
      %{card: card} = running_card(ctx, session: "sess-1")
      view = open_detail(ctx.conn, ctx.board, card)
      steer!(view)
      comment = steer_comment!(card)

      # The stopping strip's "≤ one heartbeat" label.
      assert has_element?(view, "#working-strip-stopping span.max-sm\\:hidden", "≤ one heartbeat")

      view |> element("#card-drawer-note-mode-steer") |> render_click()
      assert has_element?(view, "#card-drawer-note-mode span.max-sm\\:hidden", "shown while the agent works")

      _restarted = claim!(ctx.runner)
      run_refresh(view, card)

      # The resting strip's progress bar and the receipt's session suffix.
      assert has_element?(view, "#working-strip-progress.max-sm\\:hidden")

      assert has_element?(
               view,
               "#timeline-comment-#{comment.id}-receipt span.max-sm\\:hidden",
               "· restarted, session kept"
             )
    end

    test "the embedded drawer still renders the toggle and the receipt", ctx do
      %{card: card} = running_card(ctx, session: "sess-1")
      {:ok, comment, :restarted} = Runs.steer(card, {:user, ctx.user.id}, @steer, [])
      _restarted = claim!(ctx.runner)

      view = open_detail(ctx.conn, ctx.board, card, "&embed=1")

      assert has_element?(view, "#card-drawer-note-mode")
      assert text(view, "#timeline-comment-#{comment.id}-receipt") =~ "✓ Sent to write_plan"
    end
  end

  ## Scenario 14 — the run moves off the agent node mid-steer-mode

  test "a flush that ends the steerable state drops the toggle and returns to Note", ctx do
    %{card: card, run: run, job: job} = running_card(ctx)
    view = open_detail(ctx.conn, ctx.board, card)
    view |> element("#card-drawer-note-mode-steer") |> render_click()
    assert text(view, "#card-drawer-comment-submit .pending-idle") == "Steer now"

    {:ok, _run} = Runs.report_outcome(job, %{outcome: :needs_input, detail: "which one?"})
    assert Repo.get!(Run, run.id).status == :parked
    run_refresh(view, card)

    refute has_element?(view, "#card-drawer-note-mode")
    assert text(view, "#card-drawer-comment-submit .pending-idle") == "Add note"
    assert has_element?(view, "#card-drawer-notes", @footer)
    refute has_element?(view, "#card-drawer-note-images.border-2")
  end

  ## Scenario 15 — a forged steer push on a card with nothing to steer

  test "a note_mode steer push on a non-steerable card is ignored", ctx do
    card = new_card(ctx.board, "No run")
    view = open_detail(ctx.conn, ctx.board, card)

    render_hook(view, "note_mode", %{"mode" => "steer"})

    assert text(view, "#card-drawer-comment-submit .pending-idle") == "Add note"
    refute has_element?(view, "#card-drawer-note-images.border-2")
    assert has_element?(view, "#card-drawer-notes", @footer)

    view |> form("#card-drawer-comment-form", comment: %{body: "just a note"}) |> render_submit()
    assert [%Comment{kind: :comment}] = Repo.all(from c in Comment, where: c.card_id == ^card.id)
  end
end
