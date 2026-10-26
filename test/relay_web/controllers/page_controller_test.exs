defmodule RelayWeb.PageControllerTest do
  use RelayWeb.ConnCase, async: true

  describe "GET / when logged out" do
    test "the hero sign-up CTA is a plain button with no Google mark (RE476)", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      cta = html |> LazyHTML.from_document() |> LazyHTML.query("a#google-signin")

      assert Enum.count(cta) == 1
      assert LazyHTML.attribute(cta, "href") == ["/auth/google"]
      assert cta |> LazyHTML.query("svg") |> Enum.count() == 0
      refute html =~ "Sign in with Google"

      # RE237: the 3-way theme toggle lives in the landing nav too, not just the account
      # dropdown — this is the exact line the QUICKFIX deleted once already.
      assert html =~ ~s(role="radiogroup")
      assert html =~ ~s(data-phx-theme="dark")
    end

    test "titles the landing tab Hammock Driven Development · Hamaca (RE476)", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      title = html |> LazyHTML.from_document() |> LazyHTML.query("title") |> LazyHTML.text() |> String.trim()

      assert title == "Hammock Driven Development · Hamaca"
      refute html =~ "· Relay"
      refute html =~ "Phoenix Framework"
      refute html =~ "Hamaca · Hamaca"
    end

    # RE477 scenario 1
    test "names Hamaca in the logo and the GitHub link", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      # The landing nav has no logo <img> (its mark is a CSS dot), so the brand is its wordmark.
      assert html =~ ~s(sm:inline">Hamaca</span>)
      refute html =~ ~s(alt="Relay")
      assert html =~ ~s(aria-label="Hamaca on GitHub")
      refute html =~ ~s(aria-label="Relay on GitHub")
    end

    test "renders the marketing body sections and anchors", %{conn: conn} do
      # RE476 scenario 1: the page wrapper's direct children tell the story in order.
      ids =
        conn
        |> get(~p"/")
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("div.overflow-x-clip > section, div.overflow-x-clip > footer")
        |> Enum.map(fn node ->
          case {LazyHTML.tag(node), LazyHTML.attribute(node, "id")} do
            {["footer"], _} -> "footer"
            {_, [id]} -> id
            {_, []} -> nil
          end
        end)

      assert ids == ["top", "review", "problem", "built", "how", "stakes", "transformation", "pricing", "cta", "footer"]
    end
  end

  describe "GET / head tags (RE476)" do
    defp head_doc(conn, path), do: conn |> get(path) |> html_response(200) |> LazyHTML.from_document()

    defp content_of(doc, selector) do
      node = LazyHTML.query(doc, selector)
      assert Enum.count(node) == 1, "expected exactly one #{selector}"
      [content] = LazyHTML.attribute(node, "content")
      content
    end

    test "the landing page carries the description, OG and Twitter tags", %{conn: conn} do
      doc = head_doc(conn, ~p"/")

      assert content_of(doc, "meta[name='description']") ==
               "Hamaca turns your AI agents into a factory you can see at a glance. Your phone lights up only when a decision is yours."

      assert content_of(doc, "meta[property='og:type']") == "website"
      assert content_of(doc, "meta[property='og:site_name']") == "Hamaca"
      assert content_of(doc, "meta[property='og:title']") == "Hamaca: Hammock Driven Development"
      assert content_of(doc, "meta[name='twitter:card']") == "summary_large_image"
    end

    test "the OG/Twitter image and the OG url are absolute", %{conn: conn} do
      doc = head_doc(conn, ~p"/")
      image = RelayWeb.Endpoint.url() <> "/images/og-image.png"

      assert content_of(doc, "meta[property='og:image']") == image
      assert content_of(doc, "meta[name='twitter:image']") == image
      assert String.starts_with?(image, "http")
      assert content_of(doc, "meta[property='og:url']") == RelayWeb.Endpoint.url() <> "/"
    end

    test "/privacy carries no social meta and a Hamaca title", %{conn: conn} do
      doc = head_doc(conn, ~p"/privacy")

      assert doc |> LazyHTML.query("meta[property^='og:']") |> Enum.count() == 0
      assert doc |> LazyHTML.query("meta[name^='twitter:']") |> Enum.count() == 0
      assert doc |> LazyHTML.query("meta[name='description']") |> Enum.count() == 0
      assert doc |> LazyHTML.query("title") |> LazyHTML.text() |> String.trim() == "Privacy Policy · Hamaca"
    end

    test "the OG image is served as a PNG", %{conn: conn} do
      conn = get(conn, "/images/og-image.png")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "image/png"
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
      cta = LazyHTML.query(doc, "section#cta")
      readme = LazyHTML.query(cta, ~s(div[style*="--color-neutral"] a[href="#{@github}#readme"]))

      assert Enum.count(readme) == 1
      assert text_of(readme) == "Self-host from the README →"

      assert cta |> LazyHTML.text() |> String.replace(~r/\s+/, " ") =~
               "Open source under the MIT license. Rather run it yourself? Self-host from the README →"

      # the CTA band and the #pricing self-host card both link the README
      assert doc |> LazyHTML.query(~s(a[href="#{@github}#readme"])) |> Enum.count() == 2
    end

    test "the footer says open source (MIT) and links to Pricing and GitHub", %{conn: conn} do
      footer = conn |> landing_doc() |> LazyHTML.query("footer")

      assert LazyHTML.text(footer) =~ "hammock driven development · open source (MIT) · © 2026"
      assert footer |> LazyHTML.query("svg.hamaca-mark") |> Enum.count() == 1
      assert LazyHTML.text(footer) =~ "Hamaca"

      gh = LazyHTML.query(footer, ~s(nav a[href="#{@github}"]))
      assert Enum.count(gh) == 1
      assert text_of(gh) == "GitHub"
      assert gh |> LazyHTML.query("svg") |> Enum.count() == 1

      texts = footer |> LazyHTML.query("nav a") |> Enum.map(&text_of/1)
      assert texts == ["Terms", "Privacy", "Pricing", "Docs", "GitHub"]
      assert footer |> LazyHTML.query(~s(nav a[href="/#pricing"])) |> Enum.count() == 1
    end

    test "the hero has no GitHub button and carries the Hamaca headline", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      hero = html |> LazyHTML.from_document() |> LazyHTML.query("section#top")

      assert Enum.count(hero) == 1
      assert hero |> LazyHTML.query(~s(a[href*="github.com"])) |> Enum.count() == 0
      assert hero |> LazyHTML.query("h1") |> LazyHTML.text() =~ "Hammock Driven Development."
      refute html =~ "Pass work between people and AI"
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

  describe "GET / hero (RE476)" do
    defp hero_doc(conn), do: conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    defp squish(node), do: node |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()

    defp classes(node), do: node |> LazyHTML.attribute("class") |> Enum.flat_map(&String.split/1)

    test "scenario 1: the h1 reads Hamaca: Hammock Driven Development. with the mark", %{conn: conn} do
      h1 = conn |> hero_doc() |> LazyHTML.query("section#top h1")

      assert squish(h1) == "Hamaca: Hammock Driven Development."

      brand = LazyHTML.query(h1, "span.text-secondary")
      assert Enum.count(brand) == 1
      assert squish(brand) == "Hamaca:"
      assert brand |> LazyHTML.query("svg.hamaca-mark") |> Enum.count() == 1
    end

    test "scenario 2: the two hero CTAs start a board and watch Hamaca build itself", %{conn: conn} do
      hero = conn |> hero_doc() |> LazyHTML.query("section#top")

      start = LazyHTML.query(hero, "a#google-signin")
      assert LazyHTML.attribute(start, "href") == ["/auth/google"]
      assert "btn-primary" in classes(start)
      assert squish(start) == "Start your board"

      watch = LazyHTML.query(hero, "a#hero-watch")
      assert LazyHTML.attribute(watch, "href") == ["/board/relay/public"]
      assert "btn-outline" in classes(watch)
      assert squish(watch) == "Watch Hamaca build itself"
    end

    test "scenario 3: the hero carries the free/MIT line and the Terms and Privacy links", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      hero = html |> LazyHTML.from_document() |> LazyHTML.query("section#top")

      assert squish(hero) =~ "Free for one board. Open source (MIT). Works with Claude Code."
      assert hero |> LazyHTML.query(~s(a[href="/terms"])) |> Enum.count() == 1
      assert hero |> LazyHTML.query(~s(a[href="/privacy"])) |> Enum.count() == 1
      refute html =~ "Sign in with Google"
    end

    test "scenario 4: the nav links the story sections and starts a board", %{conn: conn} do
      doc = hero_doc(conn)
      targets = ["#review", "#how", "#built", "/#pricing"]

      links =
        doc
        |> LazyHTML.query("header nav a")
        |> Enum.filter(&(&1 |> LazyHTML.attribute("href") |> List.first() |> Kernel.in(targets)))

      assert Enum.map(links, &(&1 |> LazyHTML.attribute("href") |> List.first())) == targets
      assert Enum.map(links, &squish/1) == ["Review by looking", "How it works", "Built by Hamaca", "Pricing"]

      start = LazyHTML.query(doc, "a#nav-start")
      assert squish(start) == "Start your board"
      assert LazyHTML.attribute(start, "href") == ["/auth/google"]
      assert ~w(btn btn-primary btn-sm rounded-lg) -- classes(start) == []

      header = LazyHTML.query(doc, "header")
      assert header |> LazyHTML.query("svg.hamaca-mark") |> Enum.count() == 1
      assert squish(header) =~ "Hamaca"
      assert doc |> LazyHTML.query(~s([role="radiogroup"])) |> Enum.count() >= 1
      assert doc |> LazyHTML.query(~s([data-phx-theme="dark"])) |> Enum.count() >= 1
    end

    test "the nav wordmark hides on phones so Start your board fits at 390px", %{conn: conn} do
      brand = conn |> hero_doc() |> LazyHTML.query(~s(header nav a[href="#top"]))

      assert brand |> LazyHTML.query("svg.hamaca-mark") |> Enum.count() == 1
      wordmark = LazyHTML.query(brand, "span")
      assert squish(wordmark) == "Hamaca"
      assert ~w(hidden sm:inline) -- classes(wordmark) == []
    end

    test "scenario 6: the hero visual slot shows the lit-up notification", %{conn: conn} do
      visual = conn |> hero_doc() |> LazyHTML.query("section#top #landing-hero-visual")

      assert Enum.count(visual) == 1
      assert squish(visual) =~ "Recipe page: 2 mockups to look at"
      assert squish(visual) =~ "Tap to see them."
      assert visual |> LazyHTML.query(~s(img[src="/images/landing/lemon-spaghetti.jpg"])) |> Enum.count() == 1
    end
  end

  describe "GET / review by looking (RE476)" do
    defp review_html(conn), do: conn |> get(~p"/") |> html_response(200)

    defp review_doc(conn), do: conn |> review_html() |> LazyHTML.from_document()

    defp text(node), do: node |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()

    defp class_set(node), do: node |> LazyHTML.attribute("class") |> Enum.flat_map(&String.split/1)

    defp assert_in_order(haystack, snippets) do
      Enum.reduce(snippets, 0, fn snippet, from ->
        scope = binary_part(haystack, from, byte_size(haystack) - from)

        case :binary.match(scope, snippet) do
          {at, len} -> from + at + len
          :nomatch -> flunk("expected #{inspect(snippet)} after byte #{from} in: #{haystack}")
        end
      end)
    end

    defp board_columns(doc), do: doc |> LazyHTML.query("#landing-board > div > div") |> Enum.to_list()

    test "scenario 7: #review follows the hero with its eyebrow and headline", %{conn: conn} do
      html = review_html(conn)
      {top, _} = :binary.match(html, ~s(id="top"))
      {review, _} = :binary.match(html, ~s(id="review"))
      assert top < review

      section = html |> LazyHTML.from_document() |> LazyHTML.query("section#review")
      eyebrow = LazyHTML.query(section, ~s(div[class*="tracking-[0.08em]"]))
      assert text(eyebrow) == "REVIEW BY LOOKING"
      assert "text-success" in class_set(eyebrow)

      assert section |> LazyHTML.query("h2") |> text() ==
               "Make your life easier. Approve design docs, mockups and screenshots, not code."
    end

    test "scenario 8: the board's five column headers carry name, count and stage glyph", %{conn: conn} do
      headers = conn |> review_doc() |> LazyHTML.query("#landing-board > div > div > div:first-child") |> Enum.to_list()

      assert Enum.map(headers, &text/1) == ["Backlog 2", "Design 2", "Code 2", "Review 1", "Done 1"]

      types =
        Enum.map(headers, fn header ->
          icon = LazyHTML.query(header, ".stage-type-icon")
          assert Enum.count(icon) == 1
          icon |> LazyHTML.attribute("data-type") |> List.first()
        end)

      assert types == ["queue", "planning", "work", "review", "done"]
    end

    test "scenario 9: below lg only Design and Review show", %{conn: conn} do
      doc = review_doc(conn)
      [backlog, design, code, review, done] = board_columns(doc)

      for col <- [backlog, code, done] do
        assert "hidden" in class_set(col)
        assert "lg:block" in class_set(col)
      end

      for col <- [design, review] do
        refute "hidden" in class_set(col)
        refute "lg:block" in class_set(col)
      end

      grid = doc |> LazyHTML.query("#landing-board > div") |> class_set()
      assert "grid-cols-[2fr_1fr]" in grid
      assert "lg:grid-cols-[1fr_1.6fr_1fr_1fr_0.8fr]" in grid
    end

    test "scenario 10: exactly the two review cards are lit", %{conn: conn} do
      doc = review_doc(conn)
      lit = doc |> LazyHTML.query(~s(#landing-board [class*="ring-warning/60"])) |> Enum.map(&text/1)

      assert length(lit) == 2
      [recipe, dark] = lit
      for s <- ["Redesign the recipe page", "RE142", "review"], do: assert(recipe =~ s)
      for s <- ["Dark mode for settings", "RE157", "review"], do: assert(dark =~ s)

      [_backlog, design | _] = board_columns(doc)
      assert text(design) =~ "In progress"
      assert design |> LazyHTML.query(~s(span[class*="text-warning"])) |> text() == "Review"
    end

    test "scenario 11: the board has no YOU/AI chips, progress bars or thumbnails", %{conn: conn} do
      board = conn |> review_doc() |> LazyHTML.query("#landing-board")
      board_text = text(board)

      assert board_text =~ "Backlog"
      refute board_text =~ ~r/\bYOU\b/
      refute board_text =~ ~r/\bAI\b/
      refute board_text =~ "%"
      assert board |> LazyHTML.query("progress") |> Enum.count() == 0
      assert board |> LazyHTML.query("img") |> Enum.count() == 0
    end

    test "scenario 12: arrows on lg+, labels above each screen below lg", %{conn: conn} do
      section = conn |> review_doc() |> LazyHTML.query("section#review")

      arrows = LazyHTML.query(section, ~s([aria-hidden="true"][class*="lg:grid"]))
      assert Enum.count(arrows) == 1
      assert text(arrows) =~ "Opens with the mockups"
      assert text(arrows) =~ "Opens with screenshots"

      labels = section |> LazyHTML.query(~s([class*="lg:hidden"])) |> Enum.map(&text/1)
      assert "The Design card opens with the mockups" in labels
      assert "The Review card opens with screenshots" in labels
    end

    test "scenario 13: the browser opens the Design card's mockups", %{conn: conn} do
      browser = conn |> review_doc() |> LazyHTML.query("#landing-browser")

      assert_in_order(text(browser), [
        "Back to card",
        "Design · Review",
        "RE142",
        "Redesign the recipe page",
        "READY FOR YOUR REVIEW",
        "Hamaca AI finished this. Approve to move it forward, or send it back with a note.",
        "Approve",
        "Request changes",
        "Mockups",
        "A — photo header, two columns",
        "1 of 2",
        "Weeknight lemon pasta"
      ])

      assert browser |> LazyHTML.query("img") |> Enum.count() == 1
      assert browser |> LazyHTML.query(~s(img[src="/images/landing/lemon-spaghetti.jpg"])) |> Enum.count() == 1
    end

    test "scenario 14: the phone opens the Review card's screenshots", %{conn: conn} do
      phone = conn |> review_doc() |> LazyHTML.query("#landing-phone")

      assert_in_order(text(phone), [
        "Board",
        "RE157",
        "Review",
        "Dark mode for settings",
        "READY FOR YOUR REVIEW",
        "Hamaca AI finished this. Approve or reject below.",
        "AI Result",
        "Screenshots",
        "2",
        "Show more",
        "Reject",
        "Approve"
      ])

      buttons = phone |> LazyHTML.query("span.btn") |> Map.new(&{text(&1), class_set(&1)})
      assert "btn-primary" in buttons["Approve"]
      assert "flex-[1.4]" in buttons["Approve"]
      assert "flex-[1]" in buttons["Reject"]
    end

    test "scenario 15: the three tiles read DESIGN REVIEW, REVIEW, YOUR CALL", %{conn: conn} do
      eyebrows =
        conn
        |> review_doc()
        |> LazyHTML.query(~s(section#review [class*="sm:grid-cols-3"] > div > div:first-child))
        |> Enum.map(&text/1)

      assert eyebrows == ["DESIGN REVIEW", "REVIEW", "YOUR CALL"]
    end

    test "scenario 16: the three replicas are inert", %{conn: conn} do
      doc = review_doc(conn)

      for id <- ["#landing-board", "#landing-browser", "#landing-phone"] do
        replica = LazyHTML.query(doc, id)
        assert Enum.count(replica) == 1, "expected one #{id}"
        html = LazyHTML.to_html(replica)

        for banned <- ["phx-", "<button", "<form", "<iframe"] do
          refute html =~ banned, "expected #{id} not to contain #{inspect(banned)}"
        end

        assert doc |> LazyHTML.query("#{id} [id]") |> Enum.count() == 0, "expected no ids inside #{id}"
      end
    end

    test "scenario 17: the page never says code review or never have to read code", %{conn: conn} do
      html = conn |> review_html() |> String.downcase()

      refute html =~ "code review"
      refute html =~ "never have to read code"
    end

    test "scenario 18: the lemon photo is served as a JPEG", %{conn: conn} do
      conn = get(conn, "/images/landing/lemon-spaghetti.jpg")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "image/jpeg"
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
      assert pricing_text(free) == "Start your board, no card →"
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

    test "sits after #transformation and before the CTA band", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      {transformation, _} = :binary.match(html, ~s(id="transformation"))
      {pricing, _} = :binary.match(html, ~s(id="pricing"))
      {cta, _} = :binary.match(html, ~s(id="cta"))

      assert transformation < pricing
      assert pricing < cta
    end

    test "the pricing section never says Relay", %{conn: conn} do
      text = conn |> pricing_doc() |> LazyHTML.query("#pricing") |> pricing_text()

      assert text =~ ~r/^PRICING/
      refute text =~ "Relay"
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

  describe "GET / story sections (RE476)" do
    defp story_html(conn), do: conn |> get(~p"/") |> html_response(200)

    defp story_doc(conn), do: conn |> story_html() |> LazyHTML.from_document()

    defp story_text(node), do: node |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()

    defp story_texts(node, selector), do: node |> LazyHTML.query(selector) |> Enum.map(&story_text/1)

    defp story_classes(node), do: node |> LazyHTML.attribute("class") |> Enum.flat_map(&String.split/1)

    test "scenario 2: the old Relay sections are gone", %{conn: conn} do
      doc = story_doc(conn)

      for id <- ["#stages", "#flow", "#design"] do
        assert doc |> LazyHTML.query(id) |> Enum.count() == 0, "expected no #{id}"
      end

      text = story_text(doc)

      for gone <- [
            "Shape the stages",
            "WHEN IT'S UNSURE",
            "A question, not a wrong guess",
            "Every stage has an owner",
            "Watch a card relay across the board",
            "Give the AI a lane"
          ] do
        refute text =~ gone, "expected the page not to say #{inspect(gone)}"
      end
    end

    test "scenario 3: #problem is the silent stall with the five-terminal panel", %{conn: conn} do
      doc = story_doc(conn)
      problem = LazyHTML.query(doc, "section#problem")
      assert Enum.count(problem) == 1

      eyebrow = LazyHTML.query(problem, "section#problem > div:first-child > div.font-mono")
      assert story_text(eyebrow) == "THE SILENT STALL"
      assert "text-warning" in story_classes(eyebrow)

      h2 = LazyHTML.query(problem, "h2")
      assert story_text(h2) == "It finished an hour ago. Nothing told you."
      assert "text-[30px]" in story_classes(h2)

      assert story_texts(problem, "p") == [
               "Agents are cheap now. Coordinating them isn't. Five terminals, five worktrees, and the only way to know where each one is: read it all again. Ten minutes to rebuild context, every switch.",
               "So you can't step away. And when you do, you feel guilty about the agents sitting idle. You wanted to be a builder. You became a babysitter."
             ]

      assert ["md:grid-cols-2", "md:gap-14"] -- story_classes(problem) == []

      terminals = LazyHTML.query(problem, "#landing-terminals")
      assert Enum.count(terminals) == 1
      assert ["rounded-[14px]", "p-4", "shadow-xl"] -- story_classes(terminals) == []
      [style] = LazyHTML.attribute(terminals, "style")
      assert style =~ "--color-neutral"
      assert story_text(terminals) =~ "5 terminals"
      assert terminals |> LazyHTML.query("span.bg-neutral-content\\/25") |> Enum.count() == 3

      table = LazyHTML.query(terminals, "div.grid-cols-\\[auto_1fr_auto\\]")
      assert ["font-mono", "text-[12px]"] -- story_classes(table) == []
      cells = story_texts(table, "span")

      assert Enum.chunk_every(cells, 3) == [
               ["~/recipes", "✓ All 214 tests pass. Waiting for input.", "idle 58m"],
               ["~/trail-log", "? Should offline maps cache tiles or vectors?", "idle 41m"],
               ["~/invoices", "… writing src/pdf/render.ts", "busy"],
               ["~/blog", "✓ Ready for review: 6 files changed", "idle 2h"],
               ["~/dotfiles", "(scrolled off)", "???"]
             ]

      assert table |> LazyHTML.query("span.text-warning") |> Enum.map(&story_text/1) ==
               ["idle 58m", "idle 41m", "idle 2h"]

      assert story_texts(table, "span.text-neutral-content\\/45") == ["busy", "???"]
      assert doc |> LazyHTML.query("#landing-terminals [id]") |> Enum.count() == 0
    end

    test "scenario 4: #built carries the three guide tiles and the watch link", %{conn: conn} do
      built = conn |> story_doc() |> LazyHTML.query("section#built")
      assert Enum.count(built) == 1
      assert ["border-y", "border-base-300", "bg-base-200"] -- story_classes(built) == []

      assert story_texts(built, "h2") == ["We got tired of pacing between terminals too."]
      assert story_text(built) =~ "WE'VE BEEN THERE"

      assert story_text(built) =~
               ~s(Asking each one "are you done yet?" So we built the board we wanted, and then let it build itself.)

      tiles = LazyHTML.query(built, "div.rounded-\\[14px\\].bg-base-100")
      assert Enum.count(tiles) == 3

      eyebrows = Enum.map(tiles, &(&1 |> LazyHTML.query("div.font-mono") |> Enum.at(0) |> story_text()))
      assert eyebrows == ["BUILT BY HAMACA", "JIDOKA · ANDON", "FLOW METRICS"]

      text = story_text(built)
      assert text =~ "The light comes on when it needs you."
      assert text =~ "1 of 5 needs you"
      assert text =~ "RE476"
      assert text =~ "Hamaca landing page"
      assert text =~ "SHIPPED"

      assert text =~
               ~s(Borrowed from Toyota: machines that stop and call a person \(jidoka\), and the light on the line that says "I need you" \(andon\).)

      assert story_texts(built, "i") == ["jidoka", "andon"]

      watch = LazyHTML.query(built, "a#built-watch")
      assert LazyHTML.attribute(watch, "href") == ["/board/relay/public"]
      assert story_text(watch) == "Watch it build itself →"
      assert ["link", "link-primary"] -- story_classes(watch) == []
    end

    test "scenario 5: the FLOW METRICS tile labels its numbers as an example board", %{conn: conn} do
      tile =
        conn
        |> story_doc()
        |> LazyHTML.query("section#built div.rounded-\\[14px\\].bg-base-100")
        |> Enum.at(2)

      text = story_text(tile)
      assert text =~ "FLOW METRICS"
      assert text =~ "EXAMPLE BOARD · LEAD TIME · 8 WKS"
      assert text =~ "↓ 61%"

      bars = LazyHTML.query(tile, "span.flex-1.rounded-sm")
      assert LazyHTML.attribute(bars, "style") == Enum.map(~w(100 88 92 70 62 55 44 39), &"height:#{&1}%")
      fills = Enum.map(bars, fn bar -> Enum.find(story_classes(bar), &String.starts_with?(&1, "bg-primary")) end)
      assert fills == List.duplicate("bg-primary/70", 7) ++ ["bg-primary"]
    end

    test "scenario 6: #how walks the three steps with the real install command", %{conn: conn} do
      how = conn |> story_doc() |> LazyHTML.query("section#how")
      assert Enum.count(how) == 1

      assert story_texts(how, "h2") == ["Stop babysitting agents. Start running a factory."]

      assert story_texts(how, "h3") == [
               "Connect your repo.",
               "Draw your line.",
               "Drop in ideas. Answer when the light comes on."
             ]

      assert story_texts(how, "div.size-8.rounded-full.bg-primary") == ["1", "2", "3"]

      text = story_text(how)
      assert text =~ "HOW IT WORKS"
      assert text =~ "$ curl -fsSL hamaca.app/b/recipes/install | sh"
      assert text =~ "✓ board wired to ~/recipes"
      refute text =~ "/i/x7k"
    end

    test "scenario 7: the stage strip lists the seven stages, owner-coloured", %{conn: conn} do
      doc = story_doc(conn)
      strip = LazyHTML.query(doc, "section#how #landing-stage-strip")
      assert Enum.count(strip) == 1

      chips = LazyHTML.query(strip, "span")
      assert Enum.map(chips, &story_text/1) == ["Ideas", "Design", "Spec", "Plan", "Code", "Review", "Deploy"]

      owners =
        Enum.map(chips, fn chip ->
          classes = story_classes(chip)
          assert ["rounded-md", "border-t-[3px]", "bg-base-100", "text-[11.5px]", "font-semibold"] -- classes == []
          if "border-t-primary" in classes, do: :human, else: :ai
        end)

      assert owners == [:human, :ai, :human, :ai, :ai, :human, :ai]
      assert doc |> LazyHTML.query("#landing-stage-strip [id]") |> Enum.count() == 0
    end

    test "scenario 8: #how carries the agent question and the promises, and no board", %{conn: conn} do
      how = conn |> story_doc() |> LazyHTML.query("section#how")
      text = story_text(how)

      asked = LazyHTML.query(how, "div.border-warning\\/40.bg-warning\\/10")
      assert story_text(asked) =~ "AGENT ASKED Cache map tiles or vectors for offline mode?"
      assert asked |> story_texts("div > span") |> Enum.take(-2) == ["Tiles", "Vectors"]

      for promise <- [
            "Nothing ships without a person saying so.",
            "Agents ask instead of guessing.",
            "You can always see whose move it is."
          ] do
        assert text =~ promise
      end

      promises = LazyHTML.query(how, "div.mt-6.rounded-\\[14px\\]")
      assert ["grid", "sm:grid-cols-3", "border-base-300", "p-5"] -- story_classes(promises) == []
      assert promises |> LazyHTML.query("span.text-success") |> Enum.count() == 3

      assert how |> LazyHTML.query("#landing-board") |> Enum.count() == 0
      assert how |> LazyHTML.query(".stage-type-icon") |> Enum.count() == 0
    end

    test "scenario 9: #stakes sets what babysitting costs beside the hammock", %{conn: conn} do
      stakes = conn |> story_doc() |> LazyHTML.query("section#stakes")
      assert Enum.count(stakes) == 1
      assert "md:grid-cols-2" in story_classes(stakes)

      assert story_texts(stakes, "h2") == [
               "What babysitting costs.",
               "Ship from anywhere. Decide from your phone."
             ]

      text = story_text(stakes)
      assert text =~ "WITHOUT A LINE"
      assert text =~ "FROM THE HAMMOCK"

      [without, hammock] = stakes |> LazyHTML.query("section#stakes > div") |> Enum.to_list()
      assert "bg-base-100" in story_classes(without)
      assert ["border-success/40", "bg-success/10"] -- story_classes(hammock) == []

      assert story_texts(without, "li") == [
               "Agents finish at 9pm and sit idle until morning.",
               "Code merges that no human really looked at.",
               "Burnout from juggling terminals and context.",
               "Your best ideas die in the backlog."
             ]

      assert without |> LazyHTML.query("li span.bg-base-content\\/30") |> Enum.count() == 4

      assert story_texts(hammock, "li") == [
               "✓Ideas get built about as fast as you can describe them.",
               "✓Five projects at once, because context is one glance.",
               "✓Ship from the hammock, the trail, or the school pickup line.",
               "✓The factory needs you less every week, and you can prove it."
             ]
    end

    test "scenario 10: #transformation goes from the babysitter to the one in the hammock", %{conn: conn} do
      section = conn |> story_doc() |> LazyHTML.query("section#transformation")
      assert Enum.count(section) == 1

      text = story_text(section)

      for snippet <- ["BEFORE", "the babysitter", "AFTER", "the one in the hammock"] do
        assert text =~ snippet
      end

      assert text =~
               "You stop watching the work and start directing it, calmly, from wherever you are. Making things is fun again, and what comes out is real software."

      before = LazyHTML.query(section, "span.line-through")
      assert story_text(before) == "the babysitter"
      assert "text-base-content/45" in story_classes(before)

      assert section |> LazyHTML.query("svg.hamaca-mark") |> Enum.count() == 1
    end

    test "scenario 12: #cta says Get in the hammock with start and watch links", %{conn: conn} do
      doc = story_doc(conn)
      cta = LazyHTML.query(doc, "section#cta")
      assert Enum.count(cta) == 1

      h2 = LazyHTML.query(cta, "h2")
      assert story_text(h2) == "Get in the hammock."
      assert ["text-[34px]", "text-neutral-content"] -- story_classes(h2) == []

      assert story_text(cta) =~
               "Connect a repo, draw your line, drop in an idea. The light comes on when it needs you."

      assert cta |> LazyHTML.query("svg.hamaca-mark") |> Enum.count() == 1

      start = LazyHTML.query(cta, "a#cta-start")
      assert LazyHTML.attribute(start, "href") == ["/auth/google"]
      assert story_text(start) == "Start your board →"
      assert ["btn", "btn-primary"] -- story_classes(start) == []

      watch = LazyHTML.query(cta, "a#cta-watch")
      assert LazyHTML.attribute(watch, "href") == ["/board/relay/public"]
      assert story_text(watch) == "Watch Hamaca build itself"

      assert ["btn", "btn-ghost", "text-neutral-content", "hover:bg-neutral-content/10"] --
               story_classes(watch) == []
    end

    test "scenario 14: the footer credits the recipe photo", %{conn: conn} do
      credit = conn |> story_doc() |> LazyHTML.query("footer p#photo-credit")
      assert Enum.count(credit) == 1

      assert story_text(credit) == "Recipe photo: “Lemon Spaghetti” by Luca Nebuloni, CC BY 2.0"
      assert ["text-xs", "text-base-content/55"] -- story_classes(credit) == []

      links = LazyHTML.query(credit, "a")

      assert LazyHTML.attribute(links, "href") == [
               "https://commons.wikimedia.org/wiki/File:Lemon_Spaghetti_(14179778117).jpg",
               "https://creativecommons.org/licenses/by/2.0/"
             ]

      assert Enum.map(links, &story_text/1) == ["Lemon Spaghetti", "CC BY 2.0"]
      assert Enum.all?(links, &(["link", "link-hover"] -- story_classes(&1) == []))
    end

    test "scenario 15: the page never says code review, and the body never says Relay", %{conn: conn} do
      html = story_html(conn)
      lower = String.downcase(html)

      refute lower =~ "code review"
      refute lower =~ "never have to read code"

      body = html |> LazyHTML.from_document() |> LazyHTML.query("div.overflow-x-clip") |> LazyHTML.text()
      refute body =~ ~r/\bRelay\b/
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
