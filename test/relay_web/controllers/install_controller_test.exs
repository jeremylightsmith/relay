defmodule RelayWeb.InstallControllerTest do
  @moduledoc """
  RE443 scenario 10: `GET /b/:slug/install` serves the public install script for any
  well-formed slug — it is piped into `sh`, so it bakes `RelayWeb.Endpoint.url/0` and the
  format-checked slug, never the request's Host.
  """
  use RelayWeb.ConnCase, async: true

  test "a well-formed slug gets the plain-text sh script, board or not", %{conn: conn} do
    conn = get(conn, "/b/streaks/install")

    assert ["text/plain" <> _] = get_resp_header(conn, "content-type")
    body = response(conn, 200)
    assert String.starts_with?(body, "#!/bin/sh")
    assert body =~ RelayWeb.Endpoint.url()
    assert body =~ "streaks"
  end

  test "the request's Host never reaches the script", %{conn: conn} do
    body = %{conn | host: "evil.example"} |> get("/b/streaks/install") |> response(200)
    refute body =~ "evil.example"
  end

  test "a malformed slug is a plain 404", %{conn: conn} do
    conn = get(conn, "/b/Bad%20Slug%3B/install")

    assert ["text/plain" <> _] = get_resp_header(conn, "content-type")
    assert response(conn, 404)
  end

  test "the slug format is the board's own" do
    assert Regex.source(Schemas.Board.slug_format()) == ~S"\A[a-z0-9]+(?:-[a-z0-9]+)*\z"
  end
end
