defmodule HamacaWeb.DocsControllerTest do
  use HamacaWeb.ConnCase, async: true

  test "GET /docs renders the getting-started path, logged out", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)
    assert html =~ "Getting started"
    assert html =~ ~s(id="docs")
    refute html =~ "docs-pager-prev"
  end

  test "the docs nav ships both logo variants and swaps on the dark theme", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    assert html =~ ~s(src="/images/logo_light_128.png")
    assert html =~ ~s(src="/images/logo_dark_128.png")
    assert html =~ "dark:hidden"
    assert html =~ "hidden dark:block"
  end

  test "the getting-started path names every step of the journey", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    for needle <- [
          "Create a board",
          "RELAY_API_KEY",
          "/install",
          "/relay-onboard",
          "./relay start",
          "Settings",
          "Next up"
        ] do
      assert html =~ needle, "the getting-started page never mentions #{inspect(needle)}"
    end

    # The install bakes the board URL into ./relay, and /relay-onboard turns the flows on.
    refute html =~ "RELAY_URL"
    refute html =~ "Enable a flow"
  end

  # Order is asserted on the step HEADINGS only. Non-heading needles are unreliable for
  # ordering because the "on this page" TOC renders every heading ahead of the article
  # body, so a word that appears in a late heading precedes body text from an early step.
  # The headings themselves are monotonic in both the TOC and the body.
  test "the seven steps follow the setup checklist, in order", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    headings = [
      "1. Create a board",
      "2. Pick your LLM",
      "3. Copy your key",
      "4. Install in your repo",
      "5. Onboard with your agent",
      "6. Start the runner",
      "7. Watch your first card"
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

  test "the bootstrap step points at the board, not a third-party repo (RE304)", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    refute html =~ "RLY-181"
    refute html =~ "not available yet"
    refute html =~ "/api/scaffold"
    assert html =~ "/install"
    refute html =~ "/relay-setup"
    refute html =~ "relay-config"
    refute html =~ "install.sh"
    refute html =~ "./relay init"
  end

  test "the CLI page documents update and has retired init", %{conn: conn} do
    html = conn |> get(~p"/docs/cli") |> html_response(200)

    assert html =~ "./relay update"
    assert html =~ "--check"
    refute html =~ "./relay init"
    refute html =~ "relay-config"
    refute html =~ "publish_config"
  end

  test "the runner architecture page describes the app-served scaffold (RE304)", %{conn: conn} do
    html = conn |> get(~p"/docs/architecture-runner") |> html_response(200)

    assert html =~ "/api/scaffold"
    assert html =~ "scaffold_controller.ex"
    refute html =~ "relay-config"
    refute html =~ "published.json"
  end

  test "the getting-started page needs no repo access", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    # The sentence the whole scaffold-over-HTTP design exists to make true (plan goal).
    assert html =~ ~r/You don\S{1,6}t need the Hamaca source code/
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
      {"/docs/cli", "relay"},
      {"/docs/api", "REST API reference"},
      {"/docs/authentication", "Authentication &amp; API access"},
      {"/docs/runbook-flow-cutover", "Enabling a flow safely"},
      {"/docs/billing", "Billing &amp; self-hosting"}
    ]

    for {path, needle} <- pages do
      html = conn |> get(path) |> html_response(200)
      assert html =~ needle, "expected #{path} to render #{inspect(needle)}"
    end
  end

  test "the billing page is listed in the sidebar", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    sidebar =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("a.docs-sidebar-link")
      |> LazyHTML.text()

    assert sidebar =~ "Billing & self-hosting"
    assert html =~ ~s(href="/docs/billing")
  end

  test "the billing page has the customer FAQ headings", %{conn: conn} do
    html = conn |> get(~p"/docs/billing") |> html_response(200)

    for heading <- [
          "Which one is for you",
          "Free: one board",
          "Upgrading",
          "If a payment fails",
          "Cancelling",
          "In the mobile app"
        ] do
      assert html =~ heading, "expected /docs/billing to have the heading #{inspect(heading)}"
    end
  end

  test "the billing page states the decided terms", %{conn: conn} do
    html = conn |> get(~p"/docs/billing") |> html_response(200)

    for needle <- [
          "MIT",
          "free for one board",
          "$20 a month",
          "unlimited boards",
          "read-only",
          "nothing is deleted",
          "Members never pay",
          ~s(href="https://github.com/jeremylightsmith/relay#readme")
        ] do
      assert html =~ needle, "expected /docs/billing to mention #{inspect(needle)}"
    end

    assert html =~ ~r/no refunds/i
    refute html =~ ~r/trial|30 days/i, "Free replaced the trial (RE469); the page must not offer one"
  end

  test "the billing page leaves out promo codes and developer details", %{conn: conn} do
    html = conn |> get(~p"/docs/billing") |> html_response(200)

    for term <- ["402", "plan_paused", "BILLING_ENABLED", "Stripe", "RELAYCONF", "proration"] do
      refute html =~ term, "expected /docs/billing not to mention #{inspect(term)}"
    end

    refute html =~ ~r/promo/i, "expected /docs/billing not to mention \"promo\""
  end

  test "the billing page has no state diagram", %{conn: conn} do
    html = conn |> get(~p"/docs/billing") |> html_response(200)

    refute html =~ ~s(class="language-mermaid"), "expected /docs/billing to have no Mermaid block"
    refute html =~ "stateDiagram", "expected /docs/billing not to mention \"stateDiagram\""
  end

  test "the billing page drops the old headings", %{conn: conn} do
    html = conn |> get(~p"/docs/billing") |> html_response(200)

    for heading <- ["Paused means read-only", "If a card fails", "Promo codes", "Your free trial"] do
      refute html =~ heading, "expected /docs/billing not to have the heading #{inspect(heading)}"
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

  test "the REST API reference documents the unauthenticated scaffold endpoints (RE304)", %{
    conn: conn
  } do
    html = conn |> get(~p"/docs/api") |> html_response(200)

    assert html =~ "GET /api/scaffold"
    assert html =~ "/api/scaffold/*path"
    assert html =~ "scaffold_unavailable"
    # The blanket auth statement must carve out the unauthenticated routes it now excludes.
    assert html =~ "except"
  end

  # RE443: the install command lays down the starter runner.json (`./relay update
  # --starter-only`). Getting started only says to run the install; the CLI page has the detail.
  test "the CLI page says the install lays down runner.json and relay.md", %{conn: conn} do
    html = conn |> get(~p"/docs/cli") |> html_response(200)

    assert html =~ "./relay update --starter-only"
    assert html =~ "relay.md"
    assert html =~ ".relay/runner.json"
  end

  test "an unknown slug is a 404", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, "/docs/does-not-exist") end
  end

  test "the retired agent-integration slug is a 404 and is gone from the sidebar", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, "/docs/agent-integration") end

    html = conn |> get(~p"/docs") |> html_response(200)
    refute html =~ "Agent integration"
    refute html =~ ~s(href="/docs/agent-integration")
  end

  test "every architecture page returns 200 signed out", %{conn: conn} do
    pages = [
      {"/docs/architecture", "Hamaca architecture"},
      {"/docs/architecture-domain", "Domain model"},
      {"/docs/architecture-runtime", "Runtime"},
      {"/docs/architecture-runner", "runner"},
      {"/docs/architecture-state", "State reference"},
      {"/docs/architecture-failures", "Failure modes"},
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
          "/docs/architecture-failures",
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

  # RE477 scenario 5
  test "the sidebar sections and the docs wordmark say Hamaca", %{conn: conn} do
    document = conn |> get(~p"/docs/getting-started") |> html_response(200) |> LazyHTML.from_document()
    text = LazyHTML.text(document)

    for section <- ["Get started", "Build with Hamaca", "Operations", "Architecture"] do
      assert text =~ section
    end

    refute text =~ "Build with Relay"
    assert document |> LazyHTML.query("span") |> Enum.any?(&(LazyHTML.text(&1) == "Hamaca"))
  end

  test "the sidebar lists every page grouped into its section", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    for section <- ["Get started", "Build with Hamaca", "Operations", "Architecture"] do
      assert html =~ section
    end

    for title <- [
          "Getting started",
          "Introduction",
          "Boards &amp; stages",
          "Cards &amp; handoffs",
          "Statuses &amp; outcomes",
          "CLI (./relay)",
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
    assert breadcrumb =~ "Build with Hamaca"
    assert breadcrumb =~ "Authentication"

    eyebrow =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(".docs-eyebrow")
      |> LazyHTML.text()

    assert eyebrow =~ "BUILD WITH HAMACA"
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

  # RE477 task 3: the docs prose names the product Hamaca; commands, URLs, env vars and
  # module references stay verbatim (they're renamed by RE478/RE480/RE481).
  @top_level_slugs ~w(introduction getting-started boards-and-stages cards-and-handoffs
                      statuses-and-outcomes billing cli authentication api)

  # The rendered article's prose, with <pre> and <code> blocks removed and the tags stripped.
  defp article_prose(html) do
    article =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("article#docs")
      |> LazyHTML.to_html()

    article
    |> then(&Regex.replace(~r/<pre[\s\S]*?<\/pre>/, &1, " "))
    |> then(&Regex.replace(~r/<code[\s\S]*?<\/code>/, &1, " "))
    |> then(&Regex.replace(~r/<[^>]+>/, &1, " "))
  end

  # The raw markdown with fenced code, inline code spans and URLs removed.
  defp markdown_prose(markdown) do
    markdown
    |> then(&Regex.replace(~r/^```[\s\S]*?^```/m, &1, " "))
    |> then(&Regex.replace(~r/`[^`]*`/, &1, " "))
    |> then(&Regex.replace(~r{https?://\S+}, &1, " "))
  end

  test "the getting-started prose says Hamaca and keeps the ./relay commands", %{conn: conn} do
    html = conn |> get(~p"/docs/getting-started") |> html_response(200)
    prose = article_prose(html)

    assert prose =~ "Hamaca"
    refute prose =~ ~r/\bRelay\b/, "getting-started prose still names Relay"
    assert html =~ "./relay"
  end

  test "the CLI page says Hamaca and leaves the commands, env vars and nav label alone",
       %{conn: conn} do
    html = conn |> get(~p"/docs/cli") |> html_response(200)

    assert article_prose(html) =~ "Hamaca"
    assert html =~ "./relay card"
    assert html =~ "RELAY_"
    assert html =~ "CLI (./relay)"
  end

  test "the API reference shows the agent as Hamaca AI", %{conn: conn} do
    html = conn |> get(~p"/docs/api") |> html_response(200)

    assert html =~ ~s("name": "#{Hamaca.Brand.agent_name()}")
    refute html =~ "Relay AI"
  end

  test "no top-level docs page names Relay in its prose" do
    for slug <- @top_level_slugs do
      prose = "priv/docs/#{slug}.md" |> File.read!() |> markdown_prose()

      hits = ~r/.{0,30}\bRelay\b.{0,30}/ |> Regex.scan(prose) |> List.flatten()
      assert hits == [], "priv/docs/#{slug}.md still names Relay: #{inspect(hits)}"
    end
  end
end
