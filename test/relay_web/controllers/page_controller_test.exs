defmodule RelayWeb.PageControllerTest do
  use RelayWeb.ConnCase, async: true

  describe "GET / when logged out" do
    test "renders the landing page hero with the branded Google button", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      # branded Google sign-in CTA (kept from the old sign-in card)
      assert html =~ "Sign in with Google"
      assert html =~ "id=\"google-signin\""
      assert html =~ ~p"/auth/google"

      # hero copy from the artboard
      assert html =~ "Pass work between people and AI"
      assert html =~ "HUMAN + AI, ONE BOARD"

      # nav "Open the board" CTA and the secondary "See how it works" ghost button
      assert html =~ "Open the board"
      assert html =~ "See how it works"

      # RE237: the 3-way theme toggle lives in the landing nav too, not just the account
      # dropdown — this is the exact line the QUICKFIX deleted once already.
      assert html =~ ~s(role="radiogroup")
      assert html =~ ~s(data-phx-theme="dark")
    end

    test "titles the landing tab with the · Relay suffix and drops the Phoenix suffix", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "AI-first kanban board · Relay"
      refute html =~ "Phoenix Framework"
      refute html =~ "Relay · Relay"
    end

    test "renders the marketing body sections and anchors", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      # section anchors the nav links target
      assert html =~ "id=\"how\""
      assert html =~ "id=\"flow\""
      assert html =~ "id=\"stages\""

      # representative headings from each section
      assert html =~ "Every stage has an owner"
      assert html =~ "A question, not a wrong guess"
      assert html =~ "Watch a card relay across the board"
      assert html =~ "Shape the stages around how you actually work"
      assert html =~ "Give the AI a lane"

      # responsive + fidelity signals
      assert html =~ "md:grid-cols-3"
      assert html =~ "overflow-x-auto"
      # the CTA band is a deliberately fixed-dark panel in both themes (RE237: --color-neutral
      # is oklch(0.32 0.02 255) in both theme blocks)
      assert html =~ "background:var(--color-neutral)"
    end
  end

  describe "GET / open source links" do
    @github "https://github.com/jeremylightsmith/relay"

    defp landing_doc(conn), do: conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    defp text_of(node), do: node |> LazyHTML.text() |> String.trim()

    test "github_url/0 returns the repo URL" do
      assert RelayWeb.PageHTML.github_url() == "https://github.com/jeremylightsmith/relay"
    end

    test "the nav has one labelled GitHub link with an icon and an lg+ label", %{conn: conn} do
      link = conn |> landing_doc() |> LazyHTML.query("a#nav-github")

      assert Enum.count(link) == 1
      assert LazyHTML.attribute(link, "href") == ["https://github.com/jeremylightsmith/relay"]
      assert LazyHTML.attribute(link, "aria-label") == ["Relay on GitHub"]
      assert link |> LazyHTML.query("svg[aria-hidden='true']") |> Enum.count() == 1

      label = LazyHTML.query(link, ~s(span[class="hidden lg:inline"]))
      assert Enum.count(label) == 1
      assert text_of(label) == "GitHub"
    end

    test "the nav GitHub link opens in the same tab and is visible on phones", %{conn: conn} do
      link = conn |> landing_doc() |> LazyHTML.query("a#nav-github")

      assert LazyHTML.attribute(link, "target") == []
      [class] = LazyHTML.attribute(link, "class")
      refute "hidden" in String.split(class)
    end

    test "the CTA band carries the open-source self-host line", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      readme = html |> LazyHTML.from_document() |> LazyHTML.query(~s(a[href="#{@github}#readme"]))

      assert Enum.count(readme) == 1
      assert text_of(readme) == "Self-host from the README →"
      assert html =~ "Relay is open source under the MIT license. Rather run it yourself?"
    end

    test "the footer says open source (MIT) and links to GitHub after Docs", %{conn: conn} do
      footer = conn |> landing_doc() |> LazyHTML.query("footer")

      assert LazyHTML.text(footer) =~ "humans + AI, one board · open source (MIT) · © 2026"

      gh = LazyHTML.query(footer, ~s(nav a[href="#{@github}"]))
      assert Enum.count(gh) == 1
      assert text_of(gh) == "GitHub"
      assert gh |> LazyHTML.query("svg") |> Enum.count() == 1

      texts = footer |> LazyHTML.query("nav a") |> Enum.map(&text_of/1)
      assert texts == ["Terms", "Privacy", "Docs", "GitHub"]
    end

    test "the hero has no GitHub button and the unchanged copy stays", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      hero = html |> LazyHTML.from_document() |> LazyHTML.query("section#top")

      assert Enum.count(hero) == 1
      assert hero |> LazyHTML.query(~s(a[href*="github.com"])) |> Enum.count() == 0
      assert html =~ "Pass work between people and AI"
      assert html =~ "Give the AI a lane. Keep your hand on the board."
    end

    test "nav and footer share the same uncorrupted octicon path", %{conn: conn} do
      doc = landing_doc(conn)
      [nav_d] = doc |> LazyHTML.query("a#nav-github svg path") |> LazyHTML.attribute("d")
      [footer_d] = doc |> LazyHTML.query(~s(footer nav a[href="#{@github}"] svg path)) |> LazyHTML.attribute("d")

      assert nav_d == footer_d
      refute nav_d =~ "1.490-"
      assert String.starts_with?(nav_d, "M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59")
    end
  end

  describe "GET / design showcase" do
    defp landing_html(conn), do: conn |> get(~p"/") |> html_response(200)

    defp design_section(conn), do: conn |> landing_html() |> LazyHTML.from_document() |> LazyHTML.query("#design")

    defp class_list(node) do
      node |> LazyHTML.attribute("class") |> Enum.flat_map(&String.split/1)
    end

    test "renders the #design section with its eyebrow and headline", %{conn: conn} do
      html = landing_html(conn)

      assert html =~ ~s(id="design")
      assert html =~ "DESIGN, BUILT IN"
      assert html =~ "See it before anyone builds it."

      eyebrow = html |> LazyHTML.from_document() |> LazyHTML.query("#design > div:first-child")
      assert eyebrow |> LazyHTML.text() |> String.trim() == "DESIGN, BUILT IN"
      assert "text-success" in class_list(eyebrow)
    end

    test "the viewer replica shows the approval moment copy", %{conn: conn} do
      text = conn |> design_section() |> LazyHTML.text()

      for snippet <- [
            "READY FOR YOUR REVIEW",
            "Approve",
            "Request changes",
            "Redesign the pricing page",
            "Design · Review",
            "RE142",
            "Viewing",
            "A — three tiers, annual toggle",
            "1 of 2",
            "1 / 2",
            "Simple pricing that grows with you",
            "Annual · save 20%",
            "POPULAR"
          ] do
        assert text =~ snippet, "expected #design to contain #{inspect(snippet)}"
      end

      assert text =~ "SSO & audit log"
    end

    test "the replica is inert: no bindings, buttons, iframes or descendant ids", %{conn: conn} do
      doc = conn |> landing_html() |> LazyHTML.from_document()
      section_html = doc |> LazyHTML.query("#design") |> LazyHTML.to_html()

      assert section_html =~ "DESIGN, BUILT IN"
      refute section_html =~ "phx-"
      refute section_html =~ "<button"
      refute section_html =~ "<iframe"
      assert doc |> LazyHTML.query("#design [id]") |> Enum.count() == 0
    end

    test "sits after When it's unsure and before The flow", %{conn: conn} do
      html = landing_html(conn)

      {unsure, _} = :binary.match(html, "A question, not a wrong guess")
      {design, _} = :binary.match(html, ~s(id="design"))
      {flow, _} = :binary.match(html, ~s(id="flow"))

      assert unsure < design
      assert design < flow
    end

    test "tile A is current, tile B dimmed, and Approve is emphasised", %{conn: conn} do
      section = design_section(conn)

      current = LazyHTML.query(section, ~s([class*="ring-2 ring-primary ring-offset-2"]))
      assert Enum.count(current) == 1
      assert LazyHTML.attribute(current, "title") == ["A — three tiers, annual toggle"]

      dimmed = LazyHTML.query(section, "span.opacity-80")
      assert Enum.count(dimmed) == 1
      assert LazyHTML.attribute(dimmed, "title") == ["B — one plan, usage slider"]

      [approve_style] =
        section
        |> LazyHTML.query("span.btn")
        |> Enum.filter(&(&1 |> LazyHTML.text() |> String.trim() == "Approve"))
        |> Enum.flat_map(&LazyHTML.attribute(&1, "style"))

      assert approve_style =~ "box-shadow:0 0 0 4px color-mix(in oklab, var(--color-success) 22%, transparent)"
    end

    test "lays out frame-first on phones and sheet-first on desktop", %{conn: conn} do
      section = design_section(conn)

      aside = LazyHTML.query(section, "aside")
      assert Enum.count(aside) == 1
      assert "order-2" in class_list(aside)
      assert "md:order-1" in class_list(aside)

      pane = LazyHTML.query(section, ~s(div[class*="md:order-2"]))
      assert Enum.count(pane) == 1
      assert "order-1" in class_list(pane)

      bar = LazyHTML.query(pane, ~s(div[class*="md:hidden"]))
      assert Enum.count(bar) == 1
      assert LazyHTML.text(bar) =~ "1 / 2"

      frame = LazyHTML.query(section, ~s(div[class*="max-h-[300px]"]))
      assert Enum.count(frame) == 1
      assert "md:max-h-none" in class_list(frame)

      assert section |> LazyHTML.query("main, header") |> Enum.count() == 0
    end

    test "the flow strip includes an AI Design stage and fits eight cards", %{conn: conn} do
      html = landing_html(conn)
      cards = html |> LazyHTML.from_document() |> LazyHTML.query(~s(section#flow div[class*="border-t-[3px]"]))

      names =
        Enum.map(cards, fn card ->
          card |> LazyHTML.query("div.text-sm") |> LazyHTML.text() |> String.trim()
        end)

      assert names == ["Backlog", "Design", "Spec", "Plan", "Code", "Review", "Deploy", "Complete"]

      design = Enum.at(cards, 1)
      assert "border-t-secondary" in class_list(design)
      owner = LazyHTML.query(design, "div.font-mono")
      assert owner |> LazyHTML.text() |> String.trim() == "AI"
      assert "text-secondary" in class_list(owner)

      assert Enum.all?(cards, &("min-w-[112px]" in class_list(&1)))
      refute html =~ "min-w-[120px]"
    end

    test "the nav gets no #design anchor", %{conn: conn} do
      hrefs =
        conn
        |> landing_html()
        |> LazyHTML.from_document()
        |> LazyHTML.query("header nav a[href^='#']")
        |> LazyHTML.attribute("href")

      assert hrefs == ["#top", "#how", "#flow", "#stages"]
    end
  end

  describe "GET / when logged in" do
    setup :register_and_log_in_user

    test "redirects to the board", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == ~p"/board"
    end
  end

  describe "public legal pages" do
    test "GET /privacy renders the privacy policy", %{conn: conn} do
      html = conn |> get(~p"/privacy") |> html_response(200)
      assert html =~ "Privacy Policy"
      assert html =~ "Google Sign-In"
    end

    test "GET /terms renders the terms of service", %{conn: conn} do
      html = conn |> get(~p"/terms") |> html_response(200)
      assert html =~ "Terms of Service"
    end

    test "the sign-in page links to terms and privacy", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~p"/terms"
      assert html =~ ~p"/privacy"
    end

    test "the sign-in page links to the API docs", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~p"/docs"
    end
  end
end
