defmodule RelayWeb.DocsControllerTest do
  use RelayWeb.ConnCase, async: true

  test "GET /docs/api renders the API reference and is reachable logged out", %{conn: conn} do
    html = conn |> get(~p"/docs/api") |> html_response(200)
    assert html =~ "API Reference"
    assert html =~ "Authorization: Bearer"
  end

  test "documents every API endpoint path", %{conn: conn} do
    html = conn |> get(~p"/docs/api") |> html_response(200)

    for fragment <- [
          "GET /api/board",
          "GET /api/cards",
          "POST /api/cards",
          "/api/cards/:ref",
          "/api/cards/:ref/move",
          "/api/cards/:ref/comments",
          "/api/cards/:ref/needs-input",
          "/api/cards/:ref/approve",
          "/api/cards/:ref/reject"
        ] do
      assert html =~ fragment, "expected the API docs to mention #{fragment}"
    end
  end

  test "documents the error envelope and status/code table", %{conn: conn} do
    html = conn |> get(~p"/docs/api") |> html_response(200)
    assert html =~ "unauthorized"
    assert html =~ "not_gated"
    assert html =~ "missing_note"
    assert html =~ "invalid_target"
  end

  test "renders the status/error-code table as HTML, not literal markdown pipes", %{conn: conn} do
    html = conn |> get(~p"/docs/api") |> html_response(200)
    assert html =~ "<table>"
    refute html =~ "| --- | --- | --- |"
  end

  test "GET /docs renders the setup guide and is reachable logged out", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    assert html =~ "id=\"docs\""
    assert html =~ "Setup"
    assert html =~ "Authorization: Bearer"
    assert html =~ "RELAY_API_KEY"
  end

  test "GET /docs points to the full REST API reference", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    assert html =~ ~p"/docs/api"
    assert html =~ "/api/board"
  end

  test "GET /docs renders the CLI table as HTML, not literal markdown pipes", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    assert html =~ "<table>"
    refute html =~ "| --- |"
  end
end
