defmodule Relay.StoryMapSeedTest do
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.StoryMap
  alias Schemas.Release

  test "create_board/2 seeds the three story-map swimlanes in order" do
    user = insert(:user)

    {:ok, board} = Boards.create_board(user, %{name: "Seeded"})

    assert Enum.map(StoryMap.list_releases(board), & &1.name) == Release.seed_names()
    assert Enum.map(StoryMap.list_releases(board), & &1.position) == [1, 2, 3]
  end

  test "the default board gets them too" do
    user = insert(:user)

    board = Boards.get_or_create_default_board(user)

    assert Enum.map(StoryMap.list_releases(board), & &1.name) == Release.seed_names()
  end

  test "each board gets its own copy" do
    user = insert(:user)
    {:ok, one} = Boards.create_board(user, %{name: "One"})
    {:ok, two} = Boards.create_board(user, %{name: "Two"})

    assert length(StoryMap.list_releases(one)) == 3
    assert length(StoryMap.list_releases(two)) == 3

    assert one |> StoryMap.list_releases() |> Enum.map(& &1.id) |> Enum.sort() !=
             two |> StoryMap.list_releases() |> Enum.map(& &1.id) |> Enum.sort()
  end
end
