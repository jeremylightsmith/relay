defmodule Relay.PresenceTest do
  @moduledoc """
  RE257 — the presence context. Two topics, both deliberately outside `Relay.Events`: the
  write-storm guard (`BoardWatch.version/1` must not move) is the load-bearing assertion here,
  because routing a 20 Hz cursor through `Events.broadcast/2` would make the CLI refetch the
  whole board on every mouse twitch.
  """
  use Relay.DataCase, async: true

  alias Phoenix.Socket.Broadcast
  alias Relay.Boards
  alias Relay.BoardWatch
  alias Relay.Presence
  alias Relay.StoryMap

  setup do
    user = insert(:user)
    board = Boards.get_or_create_default_board(user)
    %{user: user, board: board}
  end

  # A stand-in for a browser tab: a real, separately-killable process to track.
  defp tab(id), do: start_supervised!({Agent, fn -> :ok end}, id: id)

  describe "the roster" do
    test "one person with two tabs is ONE roster entry", %{user: user, board: board} do
      {:ok, _ref} = Presence.track_viewer(tab(:tab_a), board.id, user)
      {:ok, _ref} = Presence.track_viewer(tab(:tab_b), board.id, user)

      assert [person] = Presence.list_people(board.id)

      assert person == %{
               user_id: user.id,
               name: user.name,
               email: user.email,
               avatar_url: user.avatar_url
             }
    end

    test "two people are two entries, sorted deterministically", %{user: user, board: board} do
      other = insert(:user)
      {:ok, _ref} = Presence.track_viewer(tab(:tab_a), board.id, user)
      {:ok, _ref} = Presence.track_viewer(tab(:tab_b), board.id, other)

      assert [%{user_id: first}, %{user_id: second}] = Presence.list_people(board.id)
      assert first == user.id
      assert second == other.id
    end

    test "a diff reaches subscribers, and a dead tab leaves the roster", %{user: user, board: board} do
      :ok = Presence.subscribe(board.id)
      pid = tab(:tab_a)
      {:ok, _ref} = Presence.track_viewer(pid, board.id, user)

      assert_receive %Broadcast{event: "presence_diff", payload: %{joins: joins}}, 1000
      assert map_size(joins) == 1

      :ok = Agent.stop(pid)

      assert_receive %Broadcast{event: "presence_diff", payload: %{leaves: leaves}}, 1000
      assert map_size(leaves) == 1
      assert Presence.list_people(board.id) == []
    end
  end

  describe "the cursor stream" do
    test "broadcast_cursor/4 reaches a subscriber with the hue seed", %{user: user, board: board} do
      :ok = Presence.subscribe(board.id)

      assert Presence.broadcast_cursor(board.id, user, 120, 340) == :ok

      user_id = user.id
      email = user.email
      assert_receive {:story_map_cursor, ^user_id, _name, ^email, 120, 340}
    end

    test "broadcast_cursor_gone/2 reaches a subscriber", %{user: user, board: board} do
      :ok = Presence.subscribe(board.id)

      assert Presence.broadcast_cursor_gone(board.id, user.id) == :ok

      user_id = user.id
      assert_receive {:story_map_cursor_gone, ^user_id}
    end
  end

  describe "the write-storm guard" do
    test "tracking, a cursor and a view write all leave the board version alone",
         %{user: user, board: board} do
      before = BoardWatch.version(board.id)

      {:ok, _ref} = Presence.track_viewer(tab(:tab_a), board.id, user)
      :ok = Presence.broadcast_cursor(board.id, user, 1, 2)
      {:ok, _view} = StoryMap.put_view(board, "tray_open", false)

      assert BoardWatch.version(board.id) == before
    end
  end
end
