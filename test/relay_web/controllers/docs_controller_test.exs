defmodule RelayWeb.DocsControllerTest do
  use RelayWeb.ConnCase, async: true

  test "GET /docs renders the getting-started path, logged out", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)
    assert html =~ "Getting started"
    assert html =~ ~s(id="docs")
    refute html =~ "docs-pager-prev"
  end

  test "the getting-started path names every step of the journey", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    for needle <- [
          "Create a board",
          "RELAY_URL",
          "RELAY_API_KEY",
          "relay init",
          "relay execute",
          "Settings",
          "Next up"
        ] do
      assert html =~ needle, "the getting-started page never mentions #{inspect(needle)}"
    end
  end

  # Order is asserted on the step HEADINGS only. Non-heading needles are unreliable for
  # ordering because the "on this page" TOC renders every heading ahead of the article
  # body, so a word that appears in a late heading precedes body text from an early step.
  # The headings themselves are monotonic in both the TOC and the body.
  test "the seven steps are numbered and rendered in order", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    headings = [
      "1. Create a board",
      "2. Get a board API key",
      "3. Get the CLI and scaffold your project",
      "4. Start the executor",
      "5. Enable a flow",
      "6. Move a card into",
      "7. When a card does not move"
    ]

    offsets =
      Enum.map(headings, fn heading ->
        case :binary.match(html, heading) do
          {at, _} -> at
          :nomatch -> flunk("the getting-started page is missing step #{inspect(heading)}")
        end
      end)

    assert offsets == Enum.sort(offsets),
           "steps are out of order: #{inspect(Enum.zip(headings, offsets))}"
  end

  test "the unbuilt CLI-install step is flagged with a callout, not papered over",
       %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    assert html =~ "RLY-181"
    assert html =~ "not available yet"
    # The intended interface is still shown, so the page is correct the day RLY-181 lands.
    assert html =~ "/install"
    assert html =~ "relay init"
  end

  test "the getting-started page needs no repo access and links the runbook", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    assert html =~ ~s(href="/docs/runbook-flow-cutover")
    refute html =~ "git clone"
    refute html =~ "copy this file"
  end

  test "every registry page returns 200 and shows its title", %{conn: conn} do
    pages = [
      {"/docs", "Getting started"},
      {"/docs/introduction", "Introduction"},
      {"/docs/boards-and-stages", "Boards &amp; stages"},
      {"/docs/cards-and-handoffs", "Cards &amp; handoffs"},
      {"/docs/statuses-and-outcomes", "Statuses &amp; outcomes"},
      {"/docs/cli", "bin/relay"},
      {"/docs/agent-integration", "Agent integration"},
      {"/docs/api", "REST API reference"},
      {"/docs/authentication", "Authentication &amp; API access"},
      {"/docs/runbook-flow-cutover", "Enabling a flow safely"}
    ]

    for {path, needle} <- pages do
      html = conn |> get(path) |> html_response(200)
      assert html =~ needle, "expected #{path} to render #{inspect(needle)}"
    end
  end

  test "the Setup page is gone: it is now /docs/authentication and /docs/setup is a 404",
       %{conn: conn} do
    html = conn |> get(~p"/docs/authentication") |> html_response(200)
    assert html =~ "Authentication &amp; API access"
    assert html =~ "Authorization: Bearer"

    # The rename is deliberate and there is no redirect map.
    assert_error_sent 404, fn -> get(conn, "/docs/setup") end
  end

  test "no page in the sidebar is titled Setup", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    sidebar =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("a.docs-sidebar-link")
      |> LazyHTML.text()

    refute sidebar =~ "Setup"
    refute html =~ ~s(href="/docs/setup")
    assert sidebar =~ "Getting started"
    assert sidebar =~ "Authentication & API access"
    assert sidebar =~ "Enabling a flow safely"
  end

  # The landing page's sidebar link is bare `/docs` (see `Layouts.docs_link/2`), so the
  # first sidebar href being "/docs" IS the assertion that Getting started leads.
  test "the first Get started entry is the getting-started path", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    [first | _] =
      ~r/href="(\/docs[^"]*)"\s+class="docs-sidebar-link/
      |> Regex.scan(html)
      |> Enum.map(fn [_, href] -> href end)

    assert first == "/docs"
  end

  test "the Architecture overview opens as an overview, not a contributor instruction",
       %{conn: conn} do
    html = conn |> get(~p"/docs/architecture") |> html_response(200)

    overview_at = html |> :binary.match("System map") |> elem(0)

    case :binary.match(html, "a gate, not a virtue") do
      {gate_at, _} ->
        assert overview_at < gate_at,
               "the contributor gate note must not open the Architecture page"

      :nomatch ->
        :ok
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

  test "every architecture page returns 200 signed out", %{conn: conn} do
    pages = [
      {"/docs/architecture", "Relay architecture"},
      {"/docs/architecture-domain", "Domain model"},
      {"/docs/architecture-runtime", "Runtime"},
      {"/docs/architecture-runner", "runner"},
      {"/docs/architecture-state", "State reference"},
      {"/docs/architecture-deps", "Dependencies"}
    ]

    for {path, needle} <- pages do
      html = conn |> get(path) |> html_response(200)
      assert html =~ needle, "expected #{path} to render #{inspect(needle)}"
    end
  end

  test "the flow-cutover runbook renders through the symlink signed out", %{conn: conn} do
    html = conn |> get(~p"/docs/runbook-flow-cutover") |> html_response(200)

    assert html =~ "Enabling a flow safely"
    assert html =~ "Settings"
    assert html =~ "capacity"
  end

  test "the runbook reads as general guidance, with Relay's own history at the end",
       %{conn: conn} do
    html = conn |> get(~p"/docs/runbook-flow-cutover") |> html_response(200)

    # The Relay-specific cutover history is demoted to a closing note, not the body.
    assert html =~ "How Relay itself cut over"
    history_at = html |> :binary.match("How Relay itself cut over") |> elem(0)
    guidance_at = html |> :binary.match("Turn the flow on") |> elem(0)
    assert guidance_at < history_at, "the general guidance must precede the history note"

    # The sidebar carries the new section.
    assert html =~ "Operations"
    assert html =~ ~s(href="/docs/runbook-flow-cutover")
  end

  test "the sidebar carries an Architecture section", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    assert html =~ "Architecture"
    assert html =~ ~s(href="/docs/architecture-state")
  end

  test "the state reference documents all four state machines", %{conn: conn} do
    html = conn |> get(~p"/docs/architecture-state") |> html_response(200)

    for value <- ~w(running parked cancelled queued claimed revoked succeeded partial) do
      assert html =~ value, "state reference is missing #{value}"
    end
  end

  test "the get-started orientation page links to the state reference", %{conn: conn} do
    html = conn |> get(~p"/docs/statuses-and-outcomes") |> html_response(200)

    assert html =~ "Statuses"
    assert html =~ ~s(href="/docs/architecture-state")
  end

  # This is the guard that keeps dead links from shipping: on the public site a *relative*
  # link whose href still ends in .md points at a file nobody can fetch. An absolute GitHub
  # blob URL legitimately ends in .md too — that's the documented fallback (constraint 5) and
  # it does resolve, just off-site, so it is not "dead" and is excluded here.
  test "no rendered architecture page carries a relative href ending in .md", %{conn: conn} do
    for path <- [
          "/docs/architecture",
          "/docs/architecture-domain",
          "/docs/architecture-runtime",
          "/docs/architecture-runner",
          "/docs/architecture-state",
          "/docs/architecture-deps"
        ] do
      html = conn |> get(path) |> html_response(200)

      hrefs =
        ~r/href="([^"]+)"/
        |> Regex.scan(html)
        |> Enum.map(fn [_, href] -> href end)

      dead =
        hrefs
        |> Enum.reject(&String.starts_with?(&1, "http"))
        |> Enum.filter(&String.ends_with?(&1, ".md"))

      assert dead == [], "#{path} ships dead markdown links: #{inspect(dead)}"
    end
  end

  test "architecture links resolve on-site or to GitHub", %{conn: conn} do
    html = conn |> get(~p"/docs/architecture") |> html_response(200)

    assert html =~ ~s(href="/docs/architecture-domain")
    assert html =~ "https://github.com/jeremylightsmith/relay/blob/main/docs/vision.md"
  end

  test "the sidebar lists every page grouped into its section", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    for section <- ["Get started", "Build with Relay", "Operations", "Architecture"] do
      assert html =~ section
    end

    for title <- [
          "Getting started",
          "Introduction",
          "Boards &amp; stages",
          "Cards &amp; handoffs",
          "Statuses &amp; outcomes",
          "CLI (bin/relay)",
          "Agent integration",
          "REST API reference",
          "Authentication &amp; API access",
          "Enabling a flow safely"
        ] do
      assert html =~ title, "sidebar missing #{title}"
    end
  end

  test "the current page is highlighted in the sidebar", %{conn: conn} do
    html = conn |> get(~p"/docs/authentication") |> html_response(200)

    active =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("a.docs-sidebar-link.is-active")
      |> LazyHTML.text()

    assert active =~ "Authentication"
    refute active =~ "Getting started"
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
    html = conn |> get(~p"/docs/authentication") |> html_response(200)

    # authentication.md has `## Authentication`
    assert html =~ ~s(href="#authentication")
    assert html =~ ~s(id="authentication")
  end

  test "the sign-in page points builders at the docs", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ ~s(href="/docs")
  end

  test "a middle page gets both a previous and a next pager link", %{conn: conn} do
    html = conn |> get(~p"/docs/authentication") |> html_response(200)

    assert html =~ ~s(class="docs-pager")
    assert html =~ ~s(docs-pager-prev)
    assert html =~ ~s(docs-pager-next)
    # authentication's neighbours in registry order are api and runbook-flow-cutover
    assert html =~ "REST API reference"
    assert html =~ "Enabling a flow safely"
  end

  test "the first page has no previous link, the last page has no next link", %{conn: conn} do
    first = conn |> get(~p"/docs") |> html_response(200)
    refute first =~ "docs-pager-prev"
    assert first =~ "docs-pager-next"

    last = conn |> get(~p"/docs/architecture-deps") |> html_response(200)
    assert last =~ "docs-pager-prev"
    refute last =~ "docs-pager-next"
  end

  test "each page carries a breadcrumb and a section eyebrow above the article", %{conn: conn} do
    html = conn |> get(~p"/docs/authentication") |> html_response(200)

    assert html =~ ~s(class="docs-breadcrumb")
    assert html =~ ~s(class="docs-eyebrow")

    breadcrumb =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(".docs-breadcrumb")
      |> LazyHTML.text()

    assert breadcrumb =~ "Docs"
    assert breadcrumb =~ "Build with Relay"
    assert breadcrumb =~ "Authentication"

    eyebrow =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(".docs-eyebrow")
      |> LazyHTML.text()

    assert eyebrow =~ "BUILD WITH RELAY"
  end

  test "the breadcrumb and eyebrow track the page's own section", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    breadcrumb =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(".docs-breadcrumb")
      |> LazyHTML.text()

    assert breadcrumb =~ "Get started"
    assert breadcrumb =~ "Getting started"

    eyebrow =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(".docs-eyebrow")
      |> LazyHTML.text()

    assert eyebrow =~ "GET STARTED"
  end

  test "mermaid fences reach the page as language-mermaid for the client to render", %{conn: conn} do
    html = conn |> get(~p"/docs/architecture-runtime") |> html_response(200)

    assert html =~ ~s(class="language-mermaid")
    assert html =~ "flowchart LR"
  end

  test "the docs layout loads the docs-only bundle", %{conn: conn} do
    html = conn |> get(~p"/docs/architecture-runtime") |> html_response(200)

    assert html =~ "/assets/js/docs.js"
  end
end
