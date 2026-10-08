defmodule Relay.ConfigTest do
  use ExUnit.Case, async: true

  describe "get/2" do
    test "falls back to the application env when nothing overrides the key" do
      assert Relay.Config.get(:apple_client_ids) == Application.get_env(:relay, :apple_client_ids)
      assert Relay.Config.get(:apple_client_ids) == ["com.jeremylightsmith.Relay"]
    end

    test "returns the default when neither an override nor an app-env entry exists" do
      assert Relay.Config.get(:re419_absent_key, :fallback) == :fallback
      assert Relay.Config.get(:re419_absent_key) == nil
    end

    test "returns the calling process's override" do
      Process.put(:apple_client_ids, ["com.example.Test"])

      assert Relay.Config.get(:apple_client_ids, []) == ["com.example.Test"]
    end

    test "a Task sees its caller's override through $callers" do
      Process.put(:apple_client_ids, ["com.example.Test"])

      assert fn -> Relay.Config.get(:apple_client_ids) end |> Task.async() |> Task.await() ==
               ["com.example.Test"]
    end

    test "a supervised process sees the test's override through $ancestors" do
      Process.put(:apple_client_ids, ["com.example.Test"])

      agent = start_supervised!({Agent, fn -> Relay.Config.get(:apple_client_ids) end})

      assert Agent.get(agent, & &1) == ["com.example.Test"]
    end

    test "does not cache the found value into the reading process" do
      Process.put(:apple_client_ids, ["com.example.Test"])

      task =
        Task.async(fn ->
          _ = Relay.Config.get(:apple_client_ids)
          Process.get(:apple_client_ids)
        end)

      assert Task.await(task) == nil
    end

    test "returns a found false as false" do
      Process.put(:runs_auto_start, true)

      assert Relay.Config.get(:runs_auto_start, false) == true
    end
  end

  describe "git_sha/0" do
    test "returns the override" do
      Process.put(:git_sha, "abc123")

      assert Relay.Config.git_sha() == "abc123"
    end

    test "treats a false override as explicitly unset" do
      Process.put(:git_sha, false)

      assert Relay.Config.git_sha() == nil
    end

    test "falls back to the GIT_SHA OS env var" do
      assert Relay.Config.git_sha() == System.get_env("GIT_SHA")
    end
  end
end
