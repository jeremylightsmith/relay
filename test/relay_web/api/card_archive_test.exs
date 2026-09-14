defmodule RelayWeb.Api.CardArchiveTest do
  @moduledoc """
  RE318 — `POST /api/cards/:ref/archive` and `/unarchive`: the board-key API's archive and
  restore, with the live-run guard that lives at the API layer only (the board UI's Archive
  button stays unguarded).
  """
  use RelayWeb.ConnCase, async: true

  alias Relay.Activity
  alias Relay.Cards

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    backlog = insert(:stage, board: board, name: "Backlog", position: 1)
    code = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 2)
    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board, backlog: backlog, code: code}
  end

  defp ref(board, card), do: Cards.ref(board, card)

  defp activity_types(card) do
    %Schemas.Card{id: card.id}
    |> Activity.list_timeline()
    |> Enum.map(&Map.get(&1, :type))
  end

  defp reload(card), do: Relay.Repo.get!(Schemas.Card, card.id)

  describe "POST /api/cards/:ref/archive" do
    test "archives the card, logs :archived as Relay AI, and drops it from the board", %{
      conn: conn,
      board: board,
      backlog: backlog
    } do
      card = insert(:card, stage: backlog)

      body =
        conn
        |> post(~p"/api/cards/#{ref(board, card)}/archive", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      assert body["ref"] == ref(board, card)
      assert body["archived"] == true
      assert %DateTime{} = reload(card).archived_at

      assert Enum.any?(
               body["timeline"],
               &(&1["kind"] == "activity" and &1["type"] == "archived" and
                   &1["author"]["name"] == "Relay AI")
             )

      board_refs =
        conn
        |> get(~p"/api/board")
        |> json_response(200)
        |> Map.fetch!("cards")
        |> Enum.map(& &1["ref"])

      refute ref(board, card) in board_refs
    end

    # Statuses come from Schemas.Run's own partition — never a re-typed list (AGENTS.md).
    test "refuses a card with a run in ANY active status with 409 active_run and writes nothing", %{
      conn: conn,
      board: board,
      code: code
    } do
      flow = insert(:flow, board: board, key: "code", works_in_stage_id: code.id)

      for status <- Schemas.Run.active_statuses() do
        card = insert(:card, stage: code)
        insert(:run, card: card, flow_id: flow.id, flow_key: flow.key, status: status)

        body =
          conn
          |> post(~p"/api/cards/#{ref(board, card)}/archive", %{})
          |> json_response(409)

        assert body["error"]["code"] == "active_run", "a #{status} run should block archive"
        assert body["error"]["message"] =~ "relay cancel #{ref(board, card)}"
        assert is_nil(reload(card).archived_at)
        refute :archived in activity_types(card)
      end
    end

    test "a card whose runs are all terminal archives normally", %{conn: conn, board: board, code: code} do
      flow = insert(:flow, board: board, key: "code", works_in_stage_id: code.id)

      for status <- Schemas.Run.terminal_statuses() do
        card = insert(:card, stage: code)
        insert(:run, card: card, flow_id: flow.id, flow_key: flow.key, status: status)

        body = conn |> post(~p"/api/cards/#{ref(board, card)}/archive", %{}) |> json_response(200)
        assert body["data"]["archived"] == true, "a #{status} run should not block archive"
      end
    end

    test "re-archiving an archived card is a 200 that logs no second :archived entry", %{
      conn: conn,
      board: board,
      backlog: backlog
    } do
      card = insert(:card, stage: backlog)
      path = ~p"/api/cards/#{ref(board, card)}/archive"

      assert conn |> post(path, %{}) |> json_response(200)
      body = conn |> post(path, %{}) |> json_response(200)

      assert body["data"]["archived"] == true
      assert Enum.count(activity_types(card), &(&1 == :archived)) == 1
    end

    test "an unknown ref is a 404", %{conn: conn} do
      body = conn |> post(~p"/api/cards/RL999999/archive", %{}) |> json_response(404)
      assert body["error"]["code"] == "not_found"
    end

    test "a card on another board is a 404 and is left untouched", %{conn: conn} do
      foreign_board = insert(:board)
      foreign_stage = insert(:stage, board: foreign_board)
      foreign = insert(:card, stage: foreign_stage)

      assert conn |> post(~p"/api/cards/#{ref(foreign_board, foreign)}/archive", %{}) |> json_response(404)
      assert is_nil(reload(foreign).archived_at)
    end
  end

  describe "POST /api/cards/:ref/unarchive" do
    test "restores an archived card and logs :unarchived as Relay AI", %{
      conn: conn,
      board: board,
      backlog: backlog
    } do
      card = insert(:card, stage: backlog)
      {:ok, _} = Cards.archive_card(card, :agent)

      body =
        conn
        |> post(~p"/api/cards/#{ref(board, card)}/unarchive", %{})
        |> json_response(200)
        |> Map.fetch!("data")

      assert body["archived"] == false
      assert body["stage_id"] == backlog.id
      assert is_nil(reload(card).archived_at)

      assert Enum.any?(
               body["timeline"],
               &(&1["kind"] == "activity" and &1["type"] == "unarchived" and
                   &1["author"]["name"] == "Relay AI")
             )

      board_refs =
        conn
        |> get(~p"/api/board")
        |> json_response(200)
        |> Map.fetch!("cards")
        |> Enum.map(& &1["ref"])

      assert ref(board, card) in board_refs
    end

    test "is not guarded by an active run", %{conn: conn, board: board, code: code} do
      flow = insert(:flow, board: board, key: "code", works_in_stage_id: code.id)
      card = insert(:card, stage: code, archived_at: DateTime.truncate(DateTime.utc_now(), :second))
      insert(:run, card: card, flow_id: flow.id, flow_key: flow.key, status: hd(Schemas.Run.active_statuses()))

      body = conn |> post(~p"/api/cards/#{ref(board, card)}/unarchive", %{}) |> json_response(200)
      assert body["data"]["archived"] == false
    end

    test "unarchiving an active card is a 200 no-op with no :unarchived entry", %{
      conn: conn,
      board: board,
      backlog: backlog
    } do
      card = insert(:card, stage: backlog)

      body = conn |> post(~p"/api/cards/#{ref(board, card)}/unarchive", %{}) |> json_response(200)

      assert body["data"]["archived"] == false
      refute :unarchived in activity_types(card)
    end

    test "an unknown ref is a 404", %{conn: conn} do
      body = conn |> post(~p"/api/cards/RL999999/unarchive", %{}) |> json_response(404)
      assert body["error"]["code"] == "not_found"
    end

    test "a card on another board is a 404 and stays archived", %{conn: conn} do
      foreign_board = insert(:board)
      foreign_stage = insert(:stage, board: foreign_board)
      foreign = insert(:card, stage: foreign_stage, archived_at: DateTime.truncate(DateTime.utc_now(), :second))

      assert conn |> post(~p"/api/cards/#{ref(foreign_board, foreign)}/unarchive", %{}) |> json_response(404)
      assert %DateTime{} = reload(foreign).archived_at
    end
  end
end
