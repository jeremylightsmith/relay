defmodule Relay.CLITest do
  use ExUnit.Case, async: true

  alias Relay.CLI

  setup do
    System.put_env("RELAY_URL", "http://relay.test")
    System.put_env("RELAY_API_KEY", "relay_abc_def")

    on_exit(fn ->
      System.delete_env("RELAY_URL")
      System.delete_env("RELAY_API_KEY")
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(CLI, fun)

  test "board/1 renders stages and cards, and --json returns raw JSON" do
    stub(fn conn ->
      Req.Test.json(conn, %{
        "board" => %{"name" => "My board", "key" => "RLY"},
        "stages" => [%{"id" => 1, "name" => "Spec", "owner" => "human", "category" => "unstarted", "position" => 1}],
        "cards" => [
          %{
            "ref" => "RLY-1",
            "title" => "Do it",
            "status" => "working",
            "stage_id" => 1,
            "owners" => [],
            "active_owner" => nil
          }
        ]
      })
    end)

    assert {:ok, text} = CLI.board([])
    assert text =~ "My board"
    assert text =~ "Spec"
    assert text =~ "RLY-1"
    assert text =~ "Do it"

    assert {:ok, json} = CLI.board(json: true)
    assert Jason.decode!(json)["board"]["key"] == "RLY"
  end

  test "card/2 renders the card + timeline" do
    stub(fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "ref" => "RLY-1",
          "title" => "Do it",
          "status" => "in_review",
          "description" => "the details",
          "owners" => [%{"type" => "agent", "name" => "Relay AI"}],
          "active_owner" => "ai",
          "timeline" => [
            %{
              "kind" => "comment",
              "body" => "hi",
              "author" => %{"type" => "agent", "name" => "Relay AI"},
              "inserted_at" => "2026-07-07T00:00:00Z"
            }
          ]
        }
      })
    end)

    assert {:ok, text} = CLI.card("RLY-1", [])
    assert text =~ "RLY-1"
    assert text =~ "the details"
    assert text =~ "Relay AI"
    assert text =~ "hi"
  end

  test "pull/1 returns the first AI-owned card, else an unclaimed card in an AI stage" do
    stub(fn conn ->
      Req.Test.json(conn, %{
        "board" => %{"name" => "B", "key" => "RLY"},
        "stages" => [
          %{"id" => 1, "name" => "Spec", "owner" => "human", "category" => "unstarted", "position" => 1},
          %{"id" => 2, "name" => "Code", "owner" => "ai", "category" => "in_progress", "position" => 2}
        ],
        "cards" => [
          %{
            "ref" => "RLY-1",
            "title" => "Human card",
            "status" => "queued",
            "stage_id" => 1,
            "owners" => [],
            "active_owner" => nil
          },
          %{
            "ref" => "RLY-2",
            "title" => "Unclaimed AI-stage",
            "status" => "queued",
            "stage_id" => 2,
            "owners" => [],
            "active_owner" => nil
          }
        ]
      })
    end)

    assert {:ok, text} = CLI.pull([])
    assert text =~ "RLY-2"
    refute text =~ "RLY-1"
  end

  test "request/3 surfaces API errors and missing config" do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_status(404)
      |> Req.Test.json(%{"error" => %{"code" => "not_found", "message" => "No card RLY-9"}})
    end)

    assert {:error, msg} = CLI.card("RLY-9", [])
    assert msg =~ "No card RLY-9"

    System.delete_env("RELAY_API_KEY")
    assert {:error, msg2} = CLI.board([])
    assert msg2 =~ "RELAY_API_KEY"
  end

  test "comment posts and confirms" do
    stub(fn conn ->
      assert conn.method == "POST"

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "data" => %{"kind" => "comment", "body" => "on it", "author" => %{"name" => "Relay AI"}}
      })
    end)

    assert {:ok, text} = CLI.comment("RLY-1", "on it", [])
    assert text =~ "RLY-1"
  end

  test "move resolves a stage name to its id then posts" do
    stub(fn conn ->
      case conn.request_path do
        "/api/board" ->
          Req.Test.json(conn, %{
            "board" => %{"name" => "B", "key" => "RLY"},
            "stages" => [
              %{"id" => 7, "name" => "Code", "owner" => "ai", "category" => "in_progress", "position" => 2}
            ],
            "cards" => []
          })

        "/api/cards/RLY-1/move" ->
          assert conn |> Plug.Conn.read_body() |> elem(1) |> Jason.decode!() |> Access.get("stage") == 7

          Req.Test.json(conn, %{
            "data" => %{
              "ref" => "RLY-1",
              "title" => "X",
              "status" => "queued",
              "stage_id" => 7,
              "active_owner" => "ai",
              "owners" => []
            }
          })
      end
    end)

    assert {:ok, text} = CLI.move("RLY-1", "Code", [])
    assert text =~ "RLY-1"
  end

  test "move errors when the stage name is unknown" do
    stub(fn conn ->
      Req.Test.json(conn, %{"board" => %{"name" => "B", "key" => "RLY"}, "stages" => [], "cards" => []})
    end)

    assert {:error, msg} = CLI.move("RLY-1", "Nope", [])
    assert msg =~ "Nope"
  end

  test "status, needs_input, own, release hit the right endpoints" do
    stub(fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "ref" => "RLY-1",
          "title" => "X",
          "status" => "working",
          "active_owner" => "ai",
          "owners" => [%{"type" => "agent", "name" => "Relay AI"}]
        }
      })
    end)

    assert {:ok, _} = CLI.status("RLY-1", "working", [])
    assert {:ok, _} = CLI.needs_input("RLY-1", "Which region?", [])
    assert {:ok, _} = CLI.own("RLY-1", [])
    assert {:ok, _} = CLI.release("RLY-1", [])
  end

  test "create posts a new card with title only" do
    stub(fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/cards"
      assert conn |> Plug.Conn.read_body() |> elem(1) |> Jason.decode!() == %{"title" => "New one"}

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "data" => %{
          "ref" => "RLY-5",
          "title" => "New one",
          "status" => "queued",
          "stage_id" => 1,
          "active_owner" => nil,
          "owners" => []
        }
      })
    end)

    assert {:ok, text} = CLI.create("New one", [])
    assert text =~ "RLY-5"
  end

  test "create includes description and tag when given" do
    stub(fn conn ->
      body = conn |> Plug.Conn.read_body() |> elem(1) |> Jason.decode!()
      assert body == %{"title" => "T", "description" => "details", "tag" => "chore"}

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "data" => %{
          "ref" => "RLY-7",
          "title" => "T",
          "status" => "queued",
          "stage_id" => 1,
          "active_owner" => nil,
          "owners" => []
        }
      })
    end)

    assert {:ok, text} = CLI.create("T", description: "details", tag: "chore")
    assert text =~ "RLY-7"
  end

  test "create resolves --stage name to an id then posts" do
    stub(fn conn ->
      case conn.request_path do
        "/api/board" ->
          Req.Test.json(conn, %{
            "board" => %{"name" => "B", "key" => "RLY"},
            "stages" => [
              %{"id" => 3, "name" => "Backlog", "owner" => "human", "category" => "unstarted", "position" => 1}
            ],
            "cards" => []
          })

        "/api/cards" ->
          assert conn |> Plug.Conn.read_body() |> elem(1) |> Jason.decode!() |> Access.get("stage") == 3

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "data" => %{
              "ref" => "RLY-6",
              "title" => "Placed",
              "status" => "queued",
              "stage_id" => 3,
              "active_owner" => nil,
              "owners" => []
            }
          })
      end
    end)

    assert {:ok, text} = CLI.create("Placed", stage: "Backlog")
    assert text =~ "RLY-6"
  end

  test "create errors when the --stage name is unknown" do
    stub(fn conn ->
      Req.Test.json(conn, %{"board" => %{"name" => "B", "key" => "RLY"}, "stages" => [], "cards" => []})
    end)

    assert {:error, msg} = CLI.create("X", stage: "Nope")
    assert msg =~ "Nope"
  end
end
