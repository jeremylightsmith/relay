defmodule RelayWeb.Api.RunCancelTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Activity
  alias Relay.Cards
  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.NodeJob

  setup %{conn: conn} do
    FakeDispatcher.register(self())

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "API Cancel Board"})
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, user)
    {:ok, flow} = board |> Relay.Flows.get_flow!("spec") |> Relay.Flows.enable_flow()
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Cards.create_card(stage, %{title: "Cancel me"})
    start_engine!()

    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board, flow: flow, card: card, user: user}
  end

  defp running_run(card, flow) do
    {:ok, run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{}}
    Runs.get_run!(run.id)
  end

  defp parked_run(card, flow) do
    {:ok, _run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{} = job}

    {:ok, run} =
      Runs.report_outcome(job, %{outcome: :needs_input, detail: "which one?", session_id: "s_1"})

    Runs.get_run!(run.id)
  end

  defp timeline_texts(card) do
    Schemas.Card
    |> Relay.Repo.get!(card.id)
    |> Activity.list_timeline()
    # list_timeline/1 returns activities AND comments; only activities carry `text`
    # (a park posts the question as a comment, which has `body` instead).
    |> Enum.filter(&is_struct(&1, Schemas.Activity))
    |> Enum.map(& &1.text)
  end

  test "cancelling a parked run frees the card to move — the 409 is gone", ctx do
    run = parked_run(ctx.card, ctx.flow)
    ref = Cards.ref(ctx.board, ctx.card)
    # `stage` on the move route is a stage ID, not a name (CardController.get_stage/2);
    # `relay move` resolves the name client-side.
    review = Enum.find(ctx.board.stages, &(&1.name == "Spec:Review"))
    assert run.status == :parked

    # Before: the move out of the flow's work lane is refused, exactly as RE306 hit it.
    refusal =
      ctx.conn
      |> post(~p"/api/cards/#{ref}/move", %{"stage" => review.id})
      |> json_response(409)
      |> Map.fetch!("error")

    assert refusal["code"] == "would_strand_run"

    body =
      ctx.conn
      |> post(~p"/api/cards/#{ref}/cancel", %{})
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["status"] == "ok"
    assert body["run_id"] == run.id
    assert body["ref"] == ref
    assert body["previous_status"] == "parked"
    # Read off the pre-cancel run rather than hardcoded: the claim is "the node the run was
    # on", which is what a caller needs, and it survives a rename of the seeded flow's node.
    assert body["node"] == run.current_node
    assert Runs.get_run!(run.id).status == :cancelled

    # After: the same move succeeds.
    assert ctx.conn |> post(~p"/api/cards/#{ref}/move", %{"stage" => review.id}) |> json_response(200)
  end

  test "POST /api/runs/:id/cancel cancels a running run", ctx do
    run = running_run(ctx.card, ctx.flow)

    body =
      ctx.conn |> post(~p"/api/runs/#{run.id}/cancel", %{}) |> json_response(200) |> Map.fetch!("data")

    assert body["previous_status"] == "running"
    assert body["run_id"] == run.id
    assert Runs.get_run!(run.id).status == :cancelled
    assert_receive {:revoked, %NodeJob{state: :revoked}}
  end

  test "a reason reaches the card timeline", ctx do
    _run = parked_run(ctx.card, ctx.flow)
    ref = Cards.ref(ctx.board, ctx.card)

    assert ctx.conn
           |> post(~p"/api/cards/#{ref}/cancel", %{"reason" => "work already merged"})
           |> json_response(200)

    assert "run cancelled — work already merged" in timeline_texts(ctx.card)
  end

  test "a non-string reason is ignored, not a 500", ctx do
    _run = parked_run(ctx.card, ctx.flow)
    ref = Cards.ref(ctx.board, ctx.card)

    assert ctx.conn |> post(~p"/api/cards/#{ref}/cancel", %{"reason" => 5}) |> json_response(200)
    assert "run cancelled" in timeline_texts(ctx.card)
  end

  test "a card with no active run is a named 422, never a silent success", ctx do
    ref = Cards.ref(ctx.board, ctx.card)

    body =
      ctx.conn |> post(~p"/api/cards/#{ref}/cancel", %{}) |> json_response(422) |> Map.fetch!("error")

    assert body["code"] == "no_active_run"
    assert body["message"] =~ "no active run"
  end

  test "a run that already ended is the same named 422", ctx do
    run = parked_run(ctx.card, ctx.flow)
    {:ok, _cancelled} = Runs.cancel_run(run)

    body =
      ctx.conn |> post(~p"/api/runs/#{run.id}/cancel", %{}) |> json_response(422) |> Map.fetch!("error")

    assert body["code"] == "no_active_run"
  end

  test "an unknown ref, an unknown run id, and a non-numeric id are all 404", ctx do
    assert ctx.conn |> post(~p"/api/cards/NOPE-1/cancel", %{}) |> json_response(404)
    assert ctx.conn |> post(~p"/api/runs/999999/cancel", %{}) |> json_response(404)
    assert ctx.conn |> post(~p"/api/runs/abc/cancel", %{}) |> json_response(404)
  end

  test "another board's run is 404, not someone else's run killed", ctx do
    other_user = insert(:user)
    {:ok, other_board} = Relay.Boards.create_board(other_user, %{name: "Someone else"})
    other_card = insert(:card, board: other_board, stage: hd(other_board.stages))
    other_run = insert(:run, card: other_card, status: :running)

    assert ctx.conn |> post(~p"/api/runs/#{other_run.id}/cancel", %{}) |> json_response(404)
    assert Runs.get_run!(other_run.id).status == :running
  end

  test "it requires a bearer token", ctx do
    run = running_run(ctx.card, ctx.flow)

    assert build_conn() |> post(~p"/api/runs/#{run.id}/cancel", %{}) |> json_response(401)
  end
end
