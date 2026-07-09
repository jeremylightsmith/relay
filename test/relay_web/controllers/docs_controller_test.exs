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
end
