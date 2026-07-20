defmodule RelayWeb.Api.VersionControllerTest do
  use RelayWeb.ConnCase, async: false

  setup do
    original = System.get_env("GIT_SHA")

    on_exit(fn ->
      if original, do: System.put_env("GIT_SHA", original), else: System.delete_env("GIT_SHA")
    end)

    :ok
  end

  test "reports the baked SHA", %{conn: conn} do
    System.put_env("GIT_SHA", "0123456789abcdef0123456789abcdef01234567")

    body = conn |> get(~p"/api/version") |> json_response(200)

    assert body["sha"] == "0123456789abcdef0123456789abcdef01234567"
    assert body["version"] =~ ~r/\d+\.\d+\.\d+/
  end

  test "is honest rather than misleading when built with no GIT_SHA", %{conn: conn} do
    System.delete_env("GIT_SHA")

    assert conn |> get(~p"/api/version") |> json_response(200) |> Map.fetch!("sha") == "unknown"
  end

  test "needs no board key — it leaks nothing a deploy does not", %{conn: conn} do
    assert conn |> get(~p"/api/version") |> json_response(200)
  end
end
