defmodule RelayWeb.Api.AllControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Accounts
  alias Relay.Cards

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, %{token: token}} = Accounts.create_user_api_token(user)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> token), user: user}
  end

  # Board keys are not unique, so tests give each board a distinct key (same
  # convention as AllFeedTest / AllActionsTest).
  defp member_board(user, key, slug) do
    board = insert(:board, key: key, slug: slug)
    insert(:membership, board: board, user: user)
    board
  end

  defp work_stage(board), do: insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 1)

  describe "show" do
    test "returns the light card shape with pr_url", %{conn: conn, user: user} do
      board = member_board(user, "AAA", "alpha")

      card =
        insert(:card, stage: work_stage(board), pr_url: "https://github.com/acme/relay/pull/42")

      body =
        conn
        |> get(~p"/api/all/cards/#{Cards.ref(board, card)}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert body["ref"] == Cards.ref(board, card)
      assert body["title"] == card.title
      assert body["pr_url"] == "https://github.com/acme/relay/pull/42"

      # The mount fetch stays cheap: none of show/1's heavy fields ride along.
      refute Map.has_key?(body, "timeline")
      refute Map.has_key?(body, "spec")
      refute Map.has_key?(body, "plan")
      refute Map.has_key?(body, "acceptance_criteria")
    end

    test "a card without a PR serves pr_url: null — the no-chip case", %{conn: conn, user: user} do
      board = member_board(user, "AAA", "alpha")
      card = insert(:card, stage: work_stage(board))

      body =
        conn
        |> get(~p"/api/all/cards/#{Cards.ref(board, card)}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert body["pr_url"] == nil
    end

    test "401 without a bearer token" do
      assert build_conn()
             |> get(~p"/api/all/cards/AAA-1")
             |> json_response(401)
    end

    test "a ref off the user's boards is 404, never leaking that it exists", %{conn: conn} do
      other_board = member_board(insert(:user), "BBB", "beta")
      card = insert(:card, stage: work_stage(other_board))

      assert conn
             |> get(~p"/api/all/cards/#{Cards.ref(other_board, card)}")
             |> json_response(404)
             |> get_in(["error", "code"]) == "not_found"
    end

    test "?board= disambiguates a ref two same-key boards share", %{conn: conn, user: user} do
      alpha = member_board(user, "RLY", "alpha")
      beta = member_board(user, "RLY", "beta")
      insert(:card, stage: work_stage(alpha), ref_number: 7)

      insert(:card,
        stage: work_stage(beta),
        ref_number: 7,
        pr_url: "https://github.com/acme/relay/pull/9"
      )

      assert conn
             |> get(~p"/api/all/cards/RLY-7")
             |> json_response(422)
             |> get_in(["error", "code"]) == "ambiguous_ref"

      body =
        conn
        |> get(~p"/api/all/cards/RLY-7?board=beta")
        |> json_response(200)
        |> Map.fetch!("data")

      assert body["pr_url"] == "https://github.com/acme/relay/pull/9"
    end
  end
end
