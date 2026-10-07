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
      board = member_board(user, "AAA", unique_slug("alpha"))

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
      board = member_board(user, "AAA", unique_slug("alpha"))
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
      other_board = member_board(insert(:user), "BBB", unique_slug("beta"))
      card = insert(:card, stage: work_stage(other_board))

      assert conn
             |> get(~p"/api/all/cards/#{Cards.ref(other_board, card)}")
             |> json_response(404)
             |> get_in(["error", "code"]) == "not_found"
    end

    test "?board= disambiguates a ref two same-key boards share", %{conn: conn, user: user} do
      alpha = member_board(user, "RLY", unique_slug("alpha"))
      beta = member_board(user, "RLY", unique_slug("beta"))
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
        |> get(~p"/api/all/cards/RLY-7?board=#{beta.slug}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert body["pr_url"] == "https://github.com/acme/relay/pull/9"
    end
  end

  describe "boards" do
    test "lists exactly the user's boards with the switcher's fields", %{conn: conn, user: user} do
      alpha = member_board(user, "AAA", unique_slug("alpha"))
      beta = member_board(user, "BBB", unique_slug("beta"))
      _foreign = member_board(insert(:user), "ZZZ", unique_slug("zeta"))

      code = work_stage(alpha)
      insert(:card, stage: code, status: :needs_input)
      working = insert(:card, stage: code, status: :working)
      insert(:card_owner, card: working)

      data =
        conn
        |> get(~p"/api/all/boards")
        |> json_response(200)
        |> Map.fetch!("data")

      assert Enum.map(data, & &1["slug"]) == [alpha.slug, beta.slug]

      [a, b] = data

      assert a == %{
               "name" => alpha.name,
               "slug" => alpha.slug,
               "key" => "AAA",
               "needs_you_count" => 1,
               "stage_count" => 1,
               "card_count" => 2,
               "ai_active" => true,
               "starred" => false,
               "muted" => false
             }

      assert b["needs_you_count"] == 0
      assert b["ai_active"] == false
    end

    test "lists boards starred-first A–Z with a starred flag", %{conn: conn, user: user} do
      zeta = insert(:board, name: "zeta", key: "ZZZ", slug: unique_slug("zeta"))
      alpha = insert(:board, name: "Alpha", key: "AAA", slug: unique_slug("alpha"))
      mango = insert(:board, name: "mango", key: "MMM", slug: unique_slug("mango"))
      for b <- [zeta, alpha, mango], do: insert(:membership, board: b, user: user)
      {:ok, true} = Relay.Boards.set_starred(user, zeta.slug, true)

      data =
        conn
        |> get(~p"/api/all/boards")
        |> json_response(200)
        |> Map.fetch!("data")

      assert Enum.map(data, & &1["slug"]) == [zeta.slug, alpha.slug, mango.slug]
      assert Enum.map(data, & &1["starred"]) == [true, false, false]
    end

    test "needs_you_count is the two-type count (ADR 0005), never the web's three-type sum",
         %{conn: conn, user: user} do
      board = member_board(user, "AAA", unique_slug("alpha"))
      code = work_stage(board)
      human = insert(:stage, board: board, name: "Polish", type: :work, ai_enabled: false, position: 2)
      review = insert(:stage, board: board, name: "Review", type: :review, position: 3)

      insert(:card, stage: code, status: :needs_input)
      insert(:card, stage: review, status: :in_review)
      # agent_stalled (RLY-148): counted.
      stalled = insert(:card, stage: code, status: :working)
      insert(:card_owner, card: stalled)
      insert(:activity, card: stalled, type: :failure, text: "agent stopped")
      # Ready-and-awaiting-human: the web's third type — NOT on the wire.
      insert(:card, stage: human, status: :ready)

      [row] = conn |> get(~p"/api/all/boards") |> json_response(200) |> Map.fetch!("data")

      assert row["slug"] == board.slug
      assert row["needs_you_count"] == 3
    end

    test "401 without a bearer token" do
      assert build_conn()
             |> get(~p"/api/all/boards")
             |> json_response(401)
    end
  end

  describe "star" do
    defp boards_starred(conn) do
      conn
      |> get(~p"/api/all/boards")
      |> json_response(200)
      |> Map.fetch!("data")
      |> Map.new(&{&1["slug"], &1["starred"]})
    end

    test "stars a member board and answers the value set", %{conn: conn, user: user} do
      alpha = member_board(user, "AAA", unique_slug("alpha"))

      assert conn |> post(~p"/api/all/boards/#{alpha.slug}/star", %{"starred" => true}) |> json_response(200) ==
               %{"data" => %{"slug" => alpha.slug, "starred" => true}}
    end

    test "starring twice is an idempotent set, not a toggle", %{conn: conn, user: user} do
      alpha = member_board(user, "AAA", unique_slug("alpha"))

      for _ <- 1..2 do
        assert conn |> post(~p"/api/all/boards/#{alpha.slug}/star", %{"starred" => true}) |> json_response(200) ==
                 %{"data" => %{"slug" => alpha.slug, "starred" => true}}
      end

      assert boards_starred(conn)[alpha.slug] == true
    end

    test "a starred board moves first in GET /api/all/boards", %{conn: conn, user: user} do
      alpha = insert(:board, name: "Alpha", key: "AAA", slug: unique_slug("alpha"))
      zeta = insert(:board, name: "zeta", key: "ZZZ", slug: unique_slug("zeta"))
      for b <- [alpha, zeta], do: insert(:membership, board: b, user: user)

      conn |> post(~p"/api/all/boards/#{zeta.slug}/star", %{"starred" => true}) |> json_response(200)

      data = conn |> get(~p"/api/all/boards") |> json_response(200) |> Map.fetch!("data")
      assert Enum.map(data, & &1["slug"]) == [zeta.slug, alpha.slug]
      assert Enum.map(data, & &1["starred"]) == [true, false]
    end

    test "unstarring sets false, idempotently", %{conn: conn, user: user} do
      alpha = member_board(user, "AAA", unique_slug("alpha"))
      {:ok, true} = Relay.Boards.set_starred(user, alpha.slug, true)

      for _ <- 1..2 do
        assert conn |> post(~p"/api/all/boards/#{alpha.slug}/star", %{"starred" => false}) |> json_response(200) ==
                 %{"data" => %{"slug" => alpha.slug, "starred" => false}}
      end

      assert boards_starred(conn)[alpha.slug] == false
    end

    test "404 on a board the user is not a member of, leaving others' stars alone", %{conn: conn} do
      other = insert(:user)
      zeta = member_board(other, "ZZZ", unique_slug("zeta"))

      body = conn |> post(~p"/api/all/boards/#{zeta.slug}/star", %{"starred" => true}) |> json_response(404)
      assert body["error"]["code"] == "not_found"

      assert Relay.Repo.get_by!(Schemas.Membership, user_id: other.id, board_id: zeta.id).starred == false
    end

    test "404 on an unknown slug", %{conn: conn} do
      assert conn |> post(~p"/api/all/boards/nope/star", %{"starred" => true}) |> json_response(404)
    end

    test "422 when starred is missing", %{conn: conn, user: user} do
      alpha = member_board(user, "AAA", unique_slug("alpha"))

      assert conn |> post(~p"/api/all/boards/#{alpha.slug}/star", %{}) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_request", "message" => "starred must be a boolean"}}
    end

    test "422 when starred is not a JSON boolean, and nothing changes", %{conn: conn, user: user} do
      alpha = member_board(user, "AAA", unique_slug("alpha"))

      body = conn |> post(~p"/api/all/boards/#{alpha.slug}/star", %{"starred" => "true"}) |> json_response(422)
      assert body["error"]["code"] == "invalid_request"

      assert boards_starred(conn)[alpha.slug] == false
    end

    test "401 without a bearer token" do
      assert build_conn()
             |> post(~p"/api/all/boards/alpha/star", %{"starred" => true})
             |> json_response(401)
    end
  end

  # RE406: the switcher's per-member mute of the board's APNs pushes.
  describe "mute" do
    defp boards_muted(conn) do
      conn
      |> get(~p"/api/all/boards")
      |> json_response(200)
      |> Map.fetch!("data")
      |> Map.new(&{&1["slug"], &1["muted"]})
    end

    test "mutes a member board and answers the value set", %{conn: conn, user: user} do
      alpha = member_board(user, "AAA", unique_slug("alpha"))

      assert conn |> post(~p"/api/all/boards/#{alpha.slug}/mute", %{"muted" => true}) |> json_response(200) ==
               %{"data" => %{"slug" => alpha.slug, "muted" => true}}

      assert boards_muted(conn)[alpha.slug] == true
    end

    test "a muted board keeps its place in GET /api/all/boards", %{conn: conn, user: user} do
      alpha = insert(:board, name: "Alpha", key: "AAA", slug: unique_slug("alpha"))
      zeta = insert(:board, name: "zeta", key: "ZZZ", slug: unique_slug("zeta"))
      for b <- [alpha, zeta], do: insert(:membership, board: b, user: user)

      conn |> post(~p"/api/all/boards/#{zeta.slug}/mute", %{"muted" => true}) |> json_response(200)

      data = conn |> get(~p"/api/all/boards") |> json_response(200) |> Map.fetch!("data")
      assert Enum.map(data, & &1["slug"]) == [alpha.slug, zeta.slug]
      assert Enum.map(data, & &1["muted"]) == [false, true]
    end

    test "unmuting sets false, idempotently", %{conn: conn, user: user} do
      alpha = member_board(user, "AAA", unique_slug("alpha"))
      {:ok, true} = Relay.Boards.set_muted(user, alpha.slug, true)

      for _ <- 1..2 do
        assert conn |> post(~p"/api/all/boards/#{alpha.slug}/mute", %{"muted" => false}) |> json_response(200) ==
                 %{"data" => %{"slug" => alpha.slug, "muted" => false}}
      end

      assert boards_muted(conn)[alpha.slug] == false
    end

    test "422 when muted is not a JSON boolean, and nothing changes", %{conn: conn, user: user} do
      alpha = member_board(user, "AAA", unique_slug("alpha"))

      body = conn |> post(~p"/api/all/boards/#{alpha.slug}/mute", %{"muted" => "true"}) |> json_response(422)
      assert body["error"]["code"] == "invalid_request"

      assert boards_muted(conn)[alpha.slug] == false
    end

    test "422 when muted is missing", %{conn: conn, user: user} do
      alpha = member_board(user, "AAA", unique_slug("alpha"))

      assert conn |> post(~p"/api/all/boards/#{alpha.slug}/mute", %{}) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_request", "message" => "muted must be a boolean"}}
    end

    test "404 on an unknown slug", %{conn: conn} do
      assert conn |> post(~p"/api/all/boards/nope/mute", %{"muted" => true}) |> json_response(404)
    end

    test "404 on a board the user is not a member of, leaving others' mutes alone", %{conn: conn} do
      other = insert(:user)
      zeta = member_board(other, "ZZZ", unique_slug("zeta"))

      body = conn |> post(~p"/api/all/boards/#{zeta.slug}/mute", %{"muted" => true}) |> json_response(404)
      assert body["error"]["code"] == "not_found"

      assert Relay.Repo.get_by!(Schemas.Membership, user_id: other.id, board_id: zeta.id).muted == false
    end

    test "401 without a bearer token" do
      assert build_conn()
             |> post(~p"/api/all/boards/alpha/mute", %{"muted" => true})
             |> json_response(401)
    end
  end
end
