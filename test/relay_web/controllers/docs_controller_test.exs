defmodule RelayWeb.DocsControllerTest do
  use RelayWeb.ConnCase, async: true

  test "GET /docs renders the Introduction, logged out", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)
    assert html =~ "Introduction"
    assert html =~ "baton"
    assert html =~ ~s(id="docs")
  end

  test "every registry page returns 200 and shows its title", %{conn: conn} do
    pages = [
      {"/docs", "Introduction"},
      {"/docs/boards-and-stages", "Boards &amp; stages"},
      {"/docs/cards-and-handoffs", "Cards &amp; handoffs"},
      {"/docs/setup", "Setup"},
      {"/docs/cli", "bin/relay"},
      {"/docs/agent-integration", "Agent integration"},
      {"/docs/api", "API Reference"}
    ]

    for {path, needle} <- pages do
      html = conn |> get(path) |> html_response(200)
      assert html =~ needle, "expected #{path} to render #{inspect(needle)}"
    end
  end

  test "the REST API reference still lives at /docs/api", %{conn: conn} do
    html = conn |> get(~p"/docs/api") |> html_response(200)
    assert html =~ "Authorization: Bearer"
    assert html =~ "GET /api/board"
  end

  test "an unknown slug is a 404", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, "/docs/does-not-exist") end
  end

  test "the sidebar lists all seven pages grouped into the two sections", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    for section <- ["Get started", "Build with Relay"] do
      assert html =~ section
    end

    for title <- [
          "Introduction",
          "Boards &amp; stages",
          "Cards &amp; handoffs",
          "Setup",
          "CLI (bin/relay)",
          "Agent integration",
          "REST API reference"
        ] do
      assert html =~ title, "sidebar missing #{title}"
    end
  end

  test "the current page is highlighted in the sidebar", %{conn: conn} do
    html = conn |> get(~p"/docs/setup") |> html_response(200)

    active =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("a.docs-sidebar-link.is-active")
      |> LazyHTML.text()

    assert active =~ "Setup"
    refute active =~ "Introduction"
  end

  test "the public nav links to the board and home, with no search field", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    assert html =~ ~s(href="/board")
    assert html =~ "Open the board"
    assert html =~ ~s(class="docs-nav-brand")
    refute html =~ ~s(type="search")
    refute html =~ "Search the docs"
  end

  test "the on-this-page TOC anchors match the rendered heading ids", %{conn: conn} do
    html = conn |> get(~p"/docs/setup") |> html_response(200)

    # setup.md has `## Authentication`
    assert html =~ ~s(href="#authentication")
    assert html =~ ~s(id="authentication")
  end

  test "the sign-in page points builders at the setup guide", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ ~s(href="/docs/setup")
  end

  test "a middle page gets both a previous and a next pager link", %{conn: conn} do
    html = conn |> get(~p"/docs/setup") |> html_response(200)

    assert html =~ ~s(class="docs-pager")
    assert html =~ ~s(docs-pager-prev)
    assert html =~ ~s(docs-pager-next)
    # setup's neighbours in registry order are cards-and-handoffs and cli
    assert html =~ "Cards &amp; handoffs"
    assert html =~ "CLI (bin/relay)"
  end

  test "the first page has no previous link, the last page has no next link", %{conn: conn} do
    first = conn |> get(~p"/docs") |> html_response(200)
    refute first =~ "docs-pager-prev"
    assert first =~ "docs-pager-next"

    last = conn |> get(~p"/docs/api") |> html_response(200)
    assert last =~ "docs-pager-prev"
    refute last =~ "docs-pager-next"
  end
end
