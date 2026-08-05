defmodule RelayWeb.Api.TalkControllerTest do
  @moduledoc "RE268 — the executor's transcript transport: board-scoped, at-least-once, kind-safe."
  use RelayWeb.ConnCase, async: true

  alias Relay.Talk

  setup do
    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Talk", key: "TK"})
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, user)
    stage = List.first(board.stages)
    {:ok, card} = Relay.Cards.create_card(stage, %{title: "Board search"})
    {:ok, turn} = Talk.post_message(card, user, "why is this stuck?")

    conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

    %{conn: conn, board: board, card: card, turn: turn, user: user}
  end

  test "events are appended and a replayed batch is accepted but stored once", ctx do
    batch = %{"events" => [%{"client_seq" => 1, "kind" => "out", "text" => "answer", "dim" => false}]}

    assert %{"status" => "ok", "accepted" => 1} =
             ctx.conn |> post(~p"/api/talk/turns/#{ctx.turn.id}/events", Jason.encode!(batch)) |> json_response(200)

    assert %{"status" => "ok", "accepted" => 0} =
             ctx.conn |> post(~p"/api/talk/turns/#{ctx.turn.id}/events", Jason.encode!(batch)) |> json_response(200)

    assert ctx.card |> Talk.session_for_card() |> Talk.events() |> length() == 2
  end

  test "reporting the outcome finishes the turn and stores the claude session id", ctx do
    body = %{"status" => "done", "session_id" => "sess-9", "detail" => nil}

    assert %{"status" => "ok", "turn_state" => "done"} =
             ctx.conn |> post(~p"/api/talk/turns/#{ctx.turn.id}/outcome", Jason.encode!(body)) |> json_response(200)

    assert Talk.get_turn(ctx.turn.id).status == :done
    assert Talk.session_for_card(ctx.card).claude_session_id == "sess-9"
  end

  test "an unknown status is refused", ctx do
    body = %{"status" => "awaiting", "session_id" => nil, "detail" => nil}

    assert %{"error" => %{"code" => "unknown_status"}} =
             ctx.conn |> post(~p"/api/talk/turns/#{ctx.turn.id}/outcome", Jason.encode!(body)) |> json_response(422)
  end

  test "a non-string session_id or detail is refused, never a 500 that strands the turn", ctx do
    # Unvalidated these reach cast(…, :string), Repo.update! raises Ecto.InvalidChangesetError,
    # and the FallbackController cannot render it — a 500 AFTER finish_talk_job! has committed,
    # leaving the job :done and the turn :claimed, which wedges the card's Talk permanently.
    before = Talk.get_turn(ctx.turn.id).status

    for body <- [
          %{"status" => "done", "session_id" => 123, "detail" => nil},
          %{"status" => "done", "session_id" => nil, "detail" => %{"a" => 1}}
        ] do
      assert %{"error" => %{"code" => "invalid_outcome"}} =
               ctx.conn
               |> post(~p"/api/talk/turns/#{ctx.turn.id}/outcome", Jason.encode!(body))
               |> json_response(422)
    end

    # Refused before anything commits, so the turn is untouched — not stranded mid-finish.
    assert Talk.get_turn(ctx.turn.id).status == before
  end

  test "a non-map element in the batch is dropped, not the whole batch", ctx do
    body = %{"events" => ["oops", %{"client_seq" => 1, "kind" => "out", "text" => "answer", "dim" => false}]}

    assert %{"status" => "ok", "accepted" => 1} =
             ctx.conn |> post(~p"/api/talk/turns/#{ctx.turn.id}/events", Jason.encode!(body)) |> json_response(200)
  end

  # RE268 round 2 — these two shapes reached `Repo.insert!` and raised (`Ecto.InvalidChangesetError`
  # for the blank text, `Protocol.UndefinedError` in `to_string/1` for the object), neither an
  # `{:error, _}` the fallback controller can render. The batch 500'd and rolled back WHOLE,
  # taking every valid line with it — the exact outcome this route promises never to have.
  test "a line with no text is dropped, not the whole batch", ctx do
    body = %{
      "events" => [
        %{"client_seq" => 1, "kind" => "out", "dim" => false},
        %{"client_seq" => 2, "kind" => "out", "text" => "answer", "dim" => false}
      ]
    }

    assert %{"status" => "ok", "accepted" => 1} =
             ctx.conn |> post(~p"/api/talk/turns/#{ctx.turn.id}/events", Jason.encode!(body)) |> json_response(200)
  end

  test "a line whose text is an object is dropped, not the whole batch", ctx do
    body = %{
      "events" => [
        %{"client_seq" => 1, "kind" => "out", "text" => %{"a" => 1}, "dim" => false},
        %{"client_seq" => 2, "kind" => "out", "text" => "answer", "dim" => false}
      ]
    }

    assert %{"status" => "ok", "accepted" => 1} =
             ctx.conn |> post(~p"/api/talk/turns/#{ctx.turn.id}/events", Jason.encode!(body)) |> json_response(200)
  end

  test "events must be a list, not a bare string", ctx do
    body = %{"events" => "nope"}

    assert %{"error" => %{"code" => "invalid_events"}} =
             ctx.conn |> post(~p"/api/talk/turns/#{ctx.turn.id}/events", Jason.encode!(body)) |> json_response(422)
  end

  test "another board's key cannot reach this turn", ctx do
    other = insert(:user)
    {:ok, other_board} = Relay.Boards.create_board(other, %{name: "Other", key: "OT"})
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(other_board, other)

    conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

    body = %{"events" => [%{"client_seq" => 1, "kind" => "out", "text" => "x", "dim" => false}]}
    assert conn |> post(~p"/api/talk/turns/#{ctx.turn.id}/events", Jason.encode!(body)) |> json_response(404)
  end

  test "a talk job is refused by the flow outcome route", ctx do
    executor = insert(:executor, board: ctx.board, name: "mac-1", capacity: %{"exclusive" => 1})
    {:ok, job} = Relay.Runs.claim_next_job(executor)
    body = %{"outcome" => "succeeded", "detail" => "", "git_sha" => nil, "session_id" => nil}

    assert ctx.conn |> post(~p"/api/node-jobs/#{job.id}/outcome", Jason.encode!(body)) |> json_response(404)
  end
end
