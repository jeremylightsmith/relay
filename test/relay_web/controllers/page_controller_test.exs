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

    test "titles the landing tab with the · Hamaca suffix and drops the Phoenix suffix", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "AI-first kanban board · Hamaca"
      refute html =~ "Phoenix Framework"
      refute html =~ "Relay · Relay"
      refute html =~ "Hamaca · Hamaca"
    end

    # RE477 scenario 1
    test "names Hamaca in the logo and the GitHub link", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      # The landing nav has no logo <img> (its mark is a CSS dot), so the brand is its wordmark.
      assert html =~ ~s(tracking-[-0.02em]">Hamaca</span>)
      refute html =~ ~s(alt="Relay")
      assert html =~ ~s(aria-label="Hamaca on GitHub")
      refute html =~ ~s(aria-label="Relay on GitHub")
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
      assert LazyHTML.attribute(link, "aria-label") == ["Hamaca on GitHub"]
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
      doc = LazyHTML.from_document(html)
      readme = LazyHTML.query(doc, ~s(div[style*="--color-neutral"] a[href="#{@github}#readme"]))

      assert Enum.count(readme) == 1
      assert text_of(readme) == "Self-host from the README →"
      assert html =~ "Hamaca is open source under the MIT license. Rather run it yourself?"

      # the CTA band and the #pricing self-host card both link the README
      assert doc |> LazyHTML.query(~s(a[href="#{@github}#readme"])) |> Enum.count() == 2
    end

    test "the footer says open source (MIT) and links to Pricing and GitHub", %{conn: conn} do
      footer = conn |> landing_doc() |> LazyHTML.query("footer")

      assert LazyHTML.text(footer) =~ "humans + AI, one board · open source (MIT) · © 2026"

      gh = LazyHTML.query(footer, ~s(nav a[href="#{@github}"]))
      assert Enum.count(gh) == 1
      assert text_of(gh) == "GitHub"
      assert gh |> LazyHTML.query("svg") |> Enum.count() == 1

      texts = footer |> LazyHTML.query("nav a") |> Enum.map(&text_of/1)
      assert texts == ["Terms", "Privacy", "Pricing", "Docs", "GitHub"]
      assert footer |> LazyHTML.query(~s(nav a[href="/#pricing"])) |> Enum.count() == 1
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
            "Redesign the recipe page",
            "Design · Review",
            "RE142",
            "Viewing",
            "A — photo header, two columns",
            "1 of 2",
            "1 / 2",
            "Forkful",
            "Weeknight lemon pasta",
            "25 min · Serves 4 · Easy",
            "Ingredients",
            "Method",
            "200g spaghetti",
            "Toss with pasta, parmesan and basil."
          ] do
        assert text =~ snippet, "expected #design to contain #{inspect(snippet)}"
      end
    end

    test "the showcase sample is not a pricing page", %{conn: conn} do
      text = conn |> design_section() |> LazyHTML.text()
      lowered = String.downcase(text)

      for word <- ["pricing", "tier", "annual", "acme", "popular", "enterprise"] do
        refute lowered =~ word, "expected #design not to mention #{inspect(word)}"
      end

      refute text =~ "$"
      refute text =~ "/mo"
    end

    test "the replica is inert: no bindings, buttons, iframes or descendant ids", %{conn: conn} do
      doc = conn |> landing_html() |> LazyHTML.from_document()
      section_html = doc |> LazyHTML.query("#design") |> LazyHTML.to_html()

      assert section_html =~ "DESIGN, BUILT IN"
      refute section_html =~ "phx-"
      refute section_html =~ "<button"
      refute section_html =~ "<iframe"
      refute section_html =~ "<img"
      refute section_html =~ "<input"
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
      assert LazyHTML.attribute(current, "title") == ["A — photo header, two columns"]

      dimmed = LazyHTML.query(section, "span.opacity-80")
      assert Enum.count(dimmed) == 1
      assert LazyHTML.attribute(dimmed, "title") == ["B — one step at a time"]

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
      assert LazyHTML.text(bar) =~ "A — photo header, two columns"
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

  describe "GET / pricing" do
    @readme "https://github.com/jeremylightsmith/relay#readme"

    defp pricing_doc(conn), do: conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    defp pricing_text(node), do: node |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()

    defp pricing_classes(node), do: node |> LazyHTML.attribute("class") |> Enum.flat_map(&String.split/1)

    test "renders one #pricing section with its eyebrow and heading", %{conn: conn} do
      section = conn |> pricing_doc() |> LazyHTML.query("section#pricing")

      assert Enum.count(section) == 1

      eyebrow = LazyHTML.query(section, "div.font-mono.tracking-\\[0\\.08em\\]")
      assert pricing_text(eyebrow) == "PRICING"
      assert "text-primary" in pricing_classes(eyebrow)

      assert section |> LazyHTML.query("h2") |> pricing_text() ==
               "Start free. Pay when you want more boards."
    end

    test "renders the three tiers once each, Self-host then Free then Cloud", %{conn: conn} do
      cards =
        conn
        |> pricing_doc()
        |> LazyHTML.query("#pricing")
        |> LazyHTML.query("#pricing-self-host, #pricing-free, #pricing-cloud")

      assert LazyHTML.attribute(cards, "id") == ["pricing-self-host", "pricing-free", "pricing-cloud"]
    end

    test "the self-host card lists the free, MIT terms", %{conn: conn} do
      text = conn |> pricing_doc() |> LazyHTML.query("#pricing-self-host") |> pricing_text()

      for snippet <- [
            "SELF-HOST",
            "Free",
            "forever · MIT",
            ~s(Every feature. No "enterprise edition."),
            "Your server, your database, your keys",
            "Unlimited boards",
            "You run upgrades, backups and push certificates"
          ] do
        assert text =~ snippet, "expected #pricing-self-host to contain #{inspect(snippet)}"
      end
    end

    test "the Hamaca Cloud · Free card lists the $0, one-board terms", %{conn: conn} do
      free = conn |> pricing_doc() |> LazyHTML.query("#pricing-free")
      text = pricing_text(free)

      for snippet <- [
            "HAMACA CLOUD · FREE",
            "No card",
            "$0",
            "forever",
            "One board, every feature",
            "Agent runs, flows, iOS & Android push",
            "Invite your team. Members are free.",
            "We run upgrades and backups"
          ] do
        assert text =~ snippet, "expected #pricing-free to contain #{inspect(snippet)}"
      end

      assert free |> LazyHTML.query("b") |> pricing_text() == "One board"
    end

    test "the Hamaca Cloud card lists the $20/month unlimited-boards terms", %{conn: conn} do
      text = conn |> pricing_doc() |> LazyHTML.query("#pricing-cloud") |> pricing_text()

      for snippet <- [
            "HAMACA CLOUD",
            "$20",
            "/ month",
            "Everything in Free",
            "Unlimited boards",
            "Cancel anytime. You drop to Free; nothing is deleted."
          ] do
        assert text =~ snippet, "expected #pricing-cloud to contain #{inspect(snippet)}"
      end

      refute text =~ "$0"
      refute text =~ "No card"
    end

    test "the pricing section does not mention promo codes", %{conn: conn} do
      text = conn |> pricing_doc() |> LazyHTML.query("#pricing") |> pricing_text()

      refute text =~ "Have a code?", "expected #pricing not to mention \"Have a code?\""
    end

    test "the three CTAs link the README and the Google sign-up", %{conn: conn} do
      doc = pricing_doc(conn)

      self_host = LazyHTML.query(doc, "a#pricing-self-host-cta")
      assert LazyHTML.attribute(self_host, "href") == [@readme]
      assert pricing_text(self_host) == "Self-host from the README →"

      free = LazyHTML.query(doc, "a#pricing-free-cta")
      assert LazyHTML.attribute(free, "href") == ["/auth/google"]
      assert pricing_text(free) == "Start free, no card →"
      assert "btn-primary" in pricing_classes(free)

      cloud = LazyHTML.query(doc, "a#pricing-cloud-cta")
      assert LazyHTML.attribute(cloud, "href") == ["/auth/google"]
      assert pricing_text(cloud) == "Start free, upgrade anytime →"
      assert "btn-outline" in pricing_classes(cloud)
      refute "btn-primary" in pricing_classes(cloud)
    end

    test "the landing page never mentions a trial", %{conn: conn} do
      text = conn |> pricing_doc() |> LazyHTML.text() |> String.downcase()

      refute text =~ "trial"
      refute text =~ "1 month free"
    end

    test "the footnote states the MIT model and links to /docs/billing", %{conn: conn} do
      doc = pricing_doc(conn)

      assert doc |> LazyHTML.query("#pricing") |> pricing_text() =~
               "Hamaca is open source under the MIT license. Your $20 pays for hosting and funds the project. Monthly only for now, no refunds."

      link = LazyHTML.query(doc, "a#pricing-billing-docs")
      assert LazyHTML.attribute(link, "href") == ["/docs/billing"]
      assert pricing_text(link) == "How billing works →"
    end

    test "sits after #stages and before the CTA band", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      {stages, _} = :binary.match(html, ~s(id="stages"))
      {pricing, _} = :binary.match(html, ~s(id="pricing"))
      {cta, _} = :binary.match(html, "background:var(--color-neutral)")

      assert stages < pricing
      assert pricing < cta
    end

    test "the free card is primary and the grid is three columns from md up", %{conn: conn} do
      doc = pricing_doc(conn)

      free = pricing_classes(LazyHTML.query(doc, "#pricing-free"))
      assert "border-2" in free
      assert "border-primary" in free

      for id <- ["#pricing-self-host", "#pricing-cloud"] do
        classes = pricing_classes(LazyHTML.query(doc, id))
        assert "border-base-300" in classes, "expected #{id} to have border-base-300"
        refute "border-primary" in classes, "expected #{id} not to have border-primary"
      end

      grid = doc |> LazyHTML.query("#pricing div:has(> #pricing-cloud)") |> pricing_classes()
      assert "md:grid-cols-3" in grid
      refute "grid-cols-3" in grid
      refute "md:grid-cols-2" in grid
    end

    test "the nav links Pricing", %{conn: conn} do
      link = conn |> pricing_doc() |> LazyHTML.query(~s(header nav a[href="/#pricing"]))

      assert Enum.count(link) == 1
      assert pricing_text(link) == "Pricing"
    end
  end

  describe "GET / with a sign-up code (scenario 9)" do
    test "stashes the code in the session", %{conn: conn} do
      conn = get(conn, ~p"/?code=RELAYCONF")
      assert get_session(conn, :signup_promo_code) == "RELAYCONF"
    end

    test "ignores a blank code", %{conn: conn} do
      conn = get(conn, "/?code=%20%20")
      assert get_session(conn, :signup_promo_code) == nil
    end

    test "ignores a code over 64 bytes", %{conn: conn} do
      conn = get(conn, ~p"/?code=#{String.duplicate("A", 65)}")
      assert get_session(conn, :signup_promo_code) == nil
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

    # RE477 scenario 2
    test "GET /terms names Hamaca, never Relay", %{conn: conn} do
      html = conn |> get(~p"/terms") |> html_response(200)

      refute html =~ ~r/\bRelay\b/
      assert html =~ "govern your use of Hamaca, an AI-first kanban board"
    end

    # RE477 scenario 2
    test "GET /privacy names Hamaca, never Relay", %{conn: conn} do
      html = conn |> get(~p"/privacy") |> html_response(200)

      refute html =~ ~r/\bRelay\b/
      assert html =~ "Hamaca is an AI-first kanban board"
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
