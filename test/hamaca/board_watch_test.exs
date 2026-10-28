defmodule Hamaca.BoardWatchTest do
  use ExUnit.Case, async: true

  alias Hamaca.BoardWatch

  # BoardWatch is started by the application, so we use the running table and
  # isolate tests with unique keys rather than starting our own instance. Keys
  # are refs, never integers: async tests bump real (small, sequential) board ids
  # in the same table, so a `System.unique_integer/1` key could collide with one.

  test "version/1 on an unknown board returns 0" do
    assert BoardWatch.version(make_ref()) == 0
  end

  test "first bump seeds the counter above 0" do
    board_id = make_ref()
    assert BoardWatch.bump(board_id) > 0
  end

  test "bump/1 increments and is monotonic per board" do
    board_id = make_ref()

    v1 = BoardWatch.bump(board_id)
    v2 = BoardWatch.bump(board_id)
    v3 = BoardWatch.bump(board_id)

    assert v2 == v1 + 1
    assert v3 == v2 + 1
    assert BoardWatch.version(board_id) == v3
  end

  test "independent boards have independent counters" do
    a = make_ref()
    b = make_ref()

    va = BoardWatch.bump(a)
    _ = BoardWatch.bump(b)
    _ = BoardWatch.bump(b)

    # bumps on b never move a's counter
    assert BoardWatch.version(a) == va
  end
end
