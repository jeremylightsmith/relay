defmodule RelayWeb.TimeAgoTest do
  use ExUnit.Case, async: true

  alias RelayWeb.TimeAgo

  @now ~U[2026-08-04 12:00:00Z]

  defp at(seconds_ago), do: DateTime.add(@now, -seconds_ago, :second)

  describe "ago/2" do
    test "nil renders as an empty string" do
      assert TimeAgo.ago(@now, nil) == ""
    end

    test "under a minute reads just now" do
      assert TimeAgo.ago(@now, at(0)) == "just now"
      assert TimeAgo.ago(@now, at(59)) == "just now"
    end

    test "a minute up to the hour reads in minutes" do
      assert TimeAgo.ago(@now, at(60)) == "1m ago"
      assert TimeAgo.ago(@now, at(3599)) == "59m ago"
    end

    test "an hour up to the day reads in hours" do
      assert TimeAgo.ago(@now, at(3600)) == "1h ago"
      assert TimeAgo.ago(@now, at(86_399)) == "23h ago"
    end

    test "a day and beyond reads in days" do
      assert TimeAgo.ago(@now, at(86_400)) == "1d ago"
      assert TimeAgo.ago(@now, at(86_400 * 9)) == "9d ago"
    end

    test "a future timestamp clamps to just now rather than going negative" do
      assert TimeAgo.ago(@now, DateTime.add(@now, 120, :second)) == "just now"
    end
  end

  describe "ago/1" do
    test "measures against the current time" do
      assert TimeAgo.ago(DateTime.utc_now()) == "just now"
      assert TimeAgo.ago(DateTime.add(DateTime.utc_now(), -7200, :second)) == "2h ago"
    end

    test "nil renders as an empty string" do
      assert TimeAgo.ago(nil) == ""
    end
  end
end
