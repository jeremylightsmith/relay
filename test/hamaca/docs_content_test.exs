defmodule Hamaca.DocsContentTest do
  use ExUnit.Case, async: true

  defp read(file), do: File.read!(Application.app_dir(:hamaca, "priv/docs/#{file}"))

  @expected [
    {"introduction.md", "# Introduction"},
    {"how-hamaca-works.md", "# How Hamaca works"},
    {"authentication.md", "# Authentication & API access"},
    {"cli.md", "# CLI (`./hamaca`)"},
    {"api.md", "# REST API reference"},
    {"billing.md", "# Billing & self-hosting"}
  ]

  test "every docs page exists and starts with its expected h1" do
    for {file, h1} <- @expected do
      assert String.starts_with?(read(file), h1), "#{file} should start with #{h1}"
    end
  end

  test "the introduction explains the baton idea with a callout" do
    {:safe, html} = Hamaca.Markdown.to_docs_html(read("introduction.md"))
    assert html =~ "baton"
    assert html =~ "markdown-alert-note"
  end

  test "the CLI page documents the ./hamaca command table" do
    html = read("cli.md")

    for cmd <- ["./hamaca board", "./hamaca card", "./hamaca move", "./hamaca needs-input", "./hamaca search"] do
      assert html =~ cmd, "cli.md should mention `#{cmd}`"
    end
  end

  test "card search is documented everywhere it is described, and the known gap is gone (RE198)" do
    guide = File.read!(Path.join(File.cwd!(), "hamaca.md"))
    domain = File.read!(Path.join(File.cwd!(), "docs/architecture/domain.md"))
    api = read("api.md")

    # The card exists to close this hole — the line that named it must not survive.
    refute guide =~ "known gap"

    assert guide =~ "./hamaca search"
    assert api =~ "./hamaca search"
    assert api =~ "q=<text>"
    assert domain =~ "./relay search"
    assert domain =~ "Cards.search/3"
  end

  test "the stage commands are documented in hamaca.md and the CLI page (RE384)" do
    guide = File.read!(Path.join(File.cwd!(), "hamaca.md"))
    cli = read("cli.md")

    for cmd <- ["stages", "stage add"] do
      assert guide =~ "./hamaca #{cmd}"
      assert cli =~ "./hamaca #{cmd}"
    end

    assert cli =~ "Refused (409, nothing written)"
  end

  test "authentication.md still explains the API key + env vars" do
    html = read("authentication.md")
    assert html =~ "HAMACA_API_KEY"
    assert html =~ "Authorization: Bearer"
  end

  test "the runner and CLI pages describe the current runner, not the retired one" do
    # RLY-139: `relay watch` / `relay_config.json` / `relay pull` / `relay layout` are
    # deleted — the live public docs must not send an operator after them.
    runner = File.read!(Path.join(File.cwd!(), "docs/architecture/runner.md"))
    cli = read("cli.md")

    assert runner =~ "./relay start"
    assert runner =~ "is **deleted**", "runner.md must still record that the legacy runner is gone"

    refute cli =~ "./hamaca pull"
    refute cli =~ "./hamaca layout"
  end

  test "the runner page carries the four current operating invariants and none of the retired ones" do
    runner = File.read!(Path.join(File.cwd!(), "docs/architecture/runner.md"))

    assert runner =~ "## Operating invariants"
    assert runner =~ "One agent per working directory"
    assert runner =~ "State lives on the board"
    assert runner =~ "Each card owns its branch"
    assert runner =~ "Work travels with the card"

    # Invariants 5-8 described the retired board-runner; they are false under server-side
    # dispatch and the engine's retry/breaker budgets, so they must not be rescued.
    refute runner =~ "Readiness is positional"
    refute runner =~ "right-to-left"
    refute runner =~ "never retry-loop"
  end

  test "no doc still links to the retired /docs/agent-integration page" do
    paths = ["hamaca.md"] ++ Path.wildcard("priv/docs/*.md") ++ Path.wildcard("docs/**/*.md")

    for path <- paths, path != "docs/adr/0008-documentation-taxonomy.md" do
      refute File.read!(Path.join(File.cwd!(), path)) =~ "docs/agent-integration",
             "#{path} still links to the retired agent-integration page"
    end
  end

  test "api.md documents the bearer-authed attachment download (RE373)" do
    assert read("api.md") =~ "### GET /api/attachments/:id"
  end

  test "api.md documents every endpoint RLY-177 added" do
    api = read("api.md")

    for path <- [
          "GET /api/cards/:ref/diagnosis",
          "GET /api/cards/:ref/runs",
          "GET /api/runners",
          "GET /api/version"
        ] do
      assert api =~ path, "api.md should document `#{path}`"
    end

    # The verdict vocabulary is the contract `relay why` prints — an undocumented verdict
    # is an operator staring at a word with no meaning.
    for verdict <- ~w(dispatchable blocked_by_dependencies no_enabled_flow awaiting_capacity
                      resume_refused wip_full owned_by_human blocked_on_input run_active
                      not_eligible run_failed job_stranded job_awaiting_slot runner_outdated
                      no_runner flow_paused) do
      assert api =~ verdict, "api.md should document the `#{verdict}` verdict"
    end
  end

  # RE93 — the expected author of a dependency graph is an agent, and an agent reads hamaca.md,
  # /docs/cli and /docs/api. A verb documented nowhere it looks ships dark.
  test "the dependency surface is documented everywhere an agent reads (RE93)" do
    guide = File.read!(Path.join(File.cwd!(), "hamaca.md"))
    cli = read("cli.md")
    api = read("api.md")

    assert guide =~ "./hamaca depends"
    assert cli =~ "./hamaca depends"

    for doc <- [guide, cli] do
      assert doc =~ "--depends-on"
    end

    for token <- ["depends_on", "\"blocks\"", "unknown_refs", "dependency_cycle"] do
      assert api =~ token, "api.md should document `#{token}`"
    end
  end

  test "cli.md lists every CLI verb RLY-177 added" do
    cli = read("cli.md")

    for verb <- ["./hamaca why", "./hamaca runs", "./hamaca runners", "./hamaca version", "--field"] do
      assert cli =~ verb, "cli.md should mention `#{verb}`"
    end
  end

  # RE318 — new API endpoints: the public API reference and the architecture page must both
  # name them, including the refusal an agent will actually hit.
  test "the archive/unarchive endpoints are documented in the API reference and architecture (RE318)" do
    api = read("api.md")
    domain = File.read!(Path.join(File.cwd!(), "docs/architecture/domain.md"))

    for token <- ["POST /api/cards/:ref/archive", "POST /api/cards/:ref/unarchive", "active_run"] do
      assert api =~ token, "api.md should document `#{token}`"
      assert domain =~ token, "domain.md should document `#{token}`"
    end
  end

  # RE318 — an agent reads hamaca.md and /docs/cli; a verb documented nowhere it looks ships dark.
  test "title, archive and unarchive are documented everywhere an agent reads (RE318)" do
    guide = File.read!(Path.join(File.cwd!(), "hamaca.md"))
    cli = read("cli.md")

    for {doc, cli_name} <- [{guide, "./hamaca"}, {cli, "./hamaca"}],
        verb <- ["#{cli_name} title", "#{cli_name} archive", "unarchive"] do
      assert doc =~ verb, "expected `#{verb}` to be documented"
    end

    for doc <- [guide, cli] do
      assert doc =~ "cancel", "the archive row should say a live run must be cancelled first"
    end

    refute guide =~ "./hamaca rename"
    refute cli =~ "./hamaca rename"
  end

  # RE478 task 4 scenario 10
  test "the CLI page names HAMACA_* and has one Upgrading from ./relay section" do
    cli = read("cli.md")

    assert String.starts_with?(cli, "# CLI (`./hamaca`)")
    [note | _] = String.split(cli, "## Commands")
    assert note =~ "`HAMACA_URL`"
    assert note =~ "`HAMACA_API_KEY`"

    assert [_, upgrading] = String.split(cli, "## Upgrading from ./relay\n")
    [upgrading | _] = String.split(upgrading, "\n## ")
    upgrading = String.replace(upgrading, ~r/\s+/, " ")

    assert upgrading =~ "installs the new runner as `./relay`"
    assert upgrading =~ "the next `./relay update` renames the repo"

    for name <- ["`./relay`", "`RELAY_*`", "`.relay/`", "`relay-*` skills", "RE482"] do
      assert upgrading =~ name, "the upgrade section should name #{name}"
    end

    assert upgrading =~ "keep working"
    assert upgrading =~ "`./hamaca start`"
  end

  # RE478 task 4 scenario 11
  test "the public pages name ./hamaca and HAMACA_*, the relay names only in cli.md's upgrade section" do
    [cli_before, rest] = String.split(read("cli.md"), "## Upgrading from ./relay\n")
    cli_after = rest |> String.split("\n## ", parts: 2) |> Enum.at(1, "")

    for {name, doc} <- [
          {"cli.md", cli_before <> cli_after},
          {"getting-started.md", read("getting-started.md")},
          {"api.md", read("api.md")},
          {"authentication.md", read("authentication.md")}
        ] do
      refute doc =~ "./relay ", "#{name} still names a ./relay command"
      refute doc =~ "RELAY_API_KEY", "#{name} still names RELAY_API_KEY"
      refute doc =~ "RELAY_URL", "#{name} still names RELAY_URL"
    end
  end

  test "the glossary defines Runner and notes that older mockups use the old word (RE319)" do
    glossary = File.read!(Path.join(File.cwd!(), "docs/glossary.md"))

    assert glossary =~ "- **Runner** —"
    assert glossary =~ "older mockups still use that word"
  end

  # RE437 shipped `fan_out` / `fan_in` control nodes — the glossary, ADR 0006 and the architecture
  # pages must describe them, and nothing may still say a parallel node doesn't dispatch.
  test "fan-out regions are documented everywhere the flow model is described (RE437)" do
    glossary = File.read!(Path.join(File.cwd!(), "docs/glossary.md"))
    adr = File.read!(Path.join(File.cwd!(), "docs/adr/0006-workflow-orchestration.md"))
    runtime = File.read!(Path.join(File.cwd!(), "docs/architecture/runtime.md"))
    runner = File.read!(Path.join(File.cwd!(), "docs/architecture/runner.md"))

    for term <- ["Control node", "Fan-out region", "Branch"] do
      assert glossary =~ "- **#{term}** —", "the glossary should define **#{term}**"
    end

    refute glossary =~ ~r/`parallel`[^.\n]*(do not|does not|doesn't|don't) dispatch/

    for token <- ["`fan_out`", "`fan_in`", "RE161"] do
      assert adr =~ token
    end

    refute adr =~ "| `parallel` |", "ADR 0006's node-type table should no longer list `parallel`"
    refute adr =~ ~r/`parallel`[^.\n]*(do not|does not|doesn't|don't) dispatch/

    assert runtime =~ "run_branches"
    assert runner =~ "live count"
    assert runner =~ "concurrent node jobs per run"
  end

  # The `ai_result` shape used to live only in the drawer's private helpers, so agents invented
  # their own spelling, the strip rendered empty, and nobody found out. It is now refused at the
  # write — which only helps if the shape is written down everywhere the author looks.
  test "the AI result blob's shape and its refusal are documented everywhere an agent reads" do
    guide = File.read!(Path.join(File.cwd!(), "hamaca.md"))
    cli = read("cli.md")
    api = read("api.md")

    for doc <- [guide, cli, api], key <- ~w(summary changes screens caption) do
      assert doc =~ key, "the ai_result key `#{key}` should be documented"
    end

    # `url` is the image, not the page it was taken on — the mistake that started this.
    for {doc, cli_name} <- [{guide, "./hamaca"}, {cli, "./hamaca"}, {api, "./hamaca"}] do
      assert doc =~ "/attachments/", "the docs should show where a screen's url comes from"
      assert doc =~ "#{cli_name} attach", "`attach` is how a screenshot becomes a url"
    end

    assert guide =~ "invalid_ai_result"
    assert api =~ "invalid_ai_result"
  end

  test "the runner page documents the hard cut's refusal and the renamed roster route (RE319)" do
    runner = File.read!(Path.join(File.cwd!(), "docs/architecture/runner.md"))
    api = read("api.md")

    assert runner =~ "predates the rename"
    assert runner =~ "`GET /api/runners`"
    assert api =~ "### GET /api/runners"
    assert api =~ "runner_outdated"
  end

  # RE372 — mockups are no longer fully offline: Google Fonts is the one network exception, and
  # every passage describing the mockup sandbox must say so (and the privacy cost where noted).
  test "mockup docs name the Google Fonts exception instead of calling mockups offline" do
    style_host = URI.parse(HamacaWeb.AttachmentController.google_fonts_style_origin()).host
    font_host = URI.parse(HamacaWeb.AttachmentController.google_fonts_font_origin()).host

    api = read("api.md")
    cli = read("cli.md")
    domain = File.read!(Path.join(File.cwd!(), "docs/architecture/domain.md"))

    # relay.md only names `mockups` and links to /docs/cli, so it is not swept here.
    for {name, doc} <- [{"api.md", api}, {"cli.md", cli}, {"domain.md", domain}] do
      assert doc =~ style_host, "#{name} should name #{style_host} as the mockup stylesheet exception"
      assert doc =~ font_host, "#{name} should name #{font_host} as the mockup font exception"
      refute doc =~ "no network access (inline JS/CSS", "#{name} still calls mockups fully offline"
      refute doc =~ "every fetch blocked", "#{name} still says every fetch is blocked"
    end

    # The privacy cost is stated where the policy is documented in full.
    for {name, doc} <- [{"api.md", api}, {"domain.md", domain}] do
      assert doc =~ "request to Google", "#{name} should state that opening such a mockup sends a request to Google"
    end

    # The architecture page quotes the live policy verbatim (it wraps lines, so compare
    # whitespace-normalized).
    normalize = &String.replace(&1, ~r/\s+/, " ")
    assert normalize.(domain) =~ HamacaWeb.AttachmentController.html_csp()
  end
end
