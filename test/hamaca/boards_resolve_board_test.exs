defmodule Hamaca.BoardsResolveBoardTest do
  use Hamaca.DataCase, async: true

  alias Hamaca.Boards

  # RE519: the ONE board-name resolver the MCP tools use. Keys are not unique, so each test
  # gives its boards distinct keys unless it is testing a key collision.

  defp member_board(user, name: name, key: key, slug: slug) do
    board = insert(:board, name: name, key: key, slug: slug)
    insert(:membership, board: board, user: user)
    board
  end

  defp ids(boards), do: boards |> Enum.map(& &1.id) |> Enum.sort()

  setup do
    user = insert(:user)
    suffix = System.unique_integer([:positive])

    %{
      user: user,
      relay: member_board(user, name: "Relay", key: "RE", slug: "relay-#{suffix}"),
      hm: member_board(user, name: "Hamaca Mobile", key: "HM", slug: "hamaca-mobile-#{suffix}"),
      mb: member_board(user, name: "Mobile Brief", key: "MB", slug: "mobile-brief-#{suffix}"),
      suffix: suffix
    }
  end

  # Scenario 1
  test "a key, a slug and a name each resolve to their one board", %{user: user, relay: relay, hm: hm} do
    assert {:ok, %{id: relay_id}} = Boards.resolve_board(user, "re")
    assert relay_id == relay.id

    assert {:ok, %{id: ^relay_id}} = Boards.resolve_board(user, "relay")
    assert {:ok, %{id: ^relay_id}} = Boards.resolve_board(user, relay.slug)

    hm_id = hm.id
    assert {:ok, %{id: ^hm_id}} = Boards.resolve_board(user, "hamaca mobile")
  end

  # Scenario 2
  test "a substring that matches two names is ambiguous", %{user: user, hm: hm, mb: mb} do
    assert {:error, {:ambiguous, matches}} = Boards.resolve_board(user, "mobile")
    assert ids(matches) == ids([hm, mb])
  end

  # Scenario 3
  test "two member boards sharing a key are ambiguous", %{user: user, suffix: suffix} do
    one = member_board(user, name: "Relay One", key: "RLY", slug: "rly-one-#{suffix}")
    two = member_board(user, name: "Relay Two", key: "RLY", slug: "rly-two-#{suffix}")

    assert {:error, {:ambiguous, matches}} = Boards.resolve_board(user, "rly")
    assert ids(matches) == ids([one, two])
  end

  # Scenario 4
  test "a foreign board, an archived board and a blank query are not found, listing only the user's active boards",
       %{user: user, relay: relay, hm: hm, mb: mb, suffix: suffix} do
    secret = insert(:board, name: "Secret", key: "SE", slug: "secret-#{suffix}")
    old = member_board(user, name: "Old", key: "OL", slug: "old-#{suffix}")
    old |> Ecto.Changeset.change(archived_at: DateTime.truncate(DateTime.utc_now(), :second)) |> Repo.update!()

    for query <- ["secret", "old", "  "] do
      assert {:error, {:not_found, boards}} = Boards.resolve_board(user, query)
      assert ids(boards) == ids([relay, hm, mb])
      refute secret.id in ids(boards)
      refute old.id in ids(boards)
    end
  end
end
