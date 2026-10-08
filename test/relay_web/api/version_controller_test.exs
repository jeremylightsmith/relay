defmodule RelayWeb.Api.VersionControllerTest do
  use RelayWeb.ConnCase, async: true

  test "reports the baked SHA", %{conn: conn} do
    Process.put(:git_sha, "0123456789abcdef0123456789abcdef01234567")

    body = conn |> get(~p"/api/version") |> json_response(200)

    assert body["sha"] == "0123456789abcdef0123456789abcdef01234567"
    assert body["version"] =~ ~r/\d+\.\d+\.\d+/
  end

  test "is honest rather than misleading when built with no GIT_SHA", %{conn: conn} do
    Process.put(:git_sha, false)

    assert conn |> get(~p"/api/version") |> json_response(200) |> Map.fetch!("sha") == "unknown"
  end

  test "needs no board key — it leaks nothing a deploy does not", %{conn: conn} do
    assert conn |> get(~p"/api/version") |> json_response(200)
  end
end
