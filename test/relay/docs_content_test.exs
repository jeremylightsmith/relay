defmodule Relay.DocsContentTest do
  use ExUnit.Case, async: true

  defp read(file), do: File.read!(Application.app_dir(:relay, "priv/docs/#{file}"))

  @expected [
    {"introduction.md", "# Introduction"},
    {"boards-and-stages.md", "# Boards & stages"},
    {"cards-and-handoffs.md", "# Cards & handoffs"},
    {"authentication.md", "# Authentication & API access"},
    {"cli.md", "# CLI (`./relay`)"},
    {"api.md", "# REST API reference"}
  ]

  test "every docs page exists and starts with its expected h1" do
    for {file, h1} <- @expected do
      assert String.starts_with?(read(file), h1), "#{file} should start with #{h1}"
    end
  end

  test "the introduction explains the baton idea with a callout" do
    {:safe, html} = Relay.Markdown.to_docs_html(read("introduction.md"))
    assert html =~ "baton"
    assert html =~ "markdown-alert-note"
  end

  test "the CLI page documents the ./relay command table" do
    html = read("cli.md")

    for cmd <- ["./relay board", "./relay card", "./relay move", "./relay needs-input", "./relay search"] do
      assert html =~ cmd, "cli.md should mention `#{cmd}`"
    end
  end

  test "card search is documented everywhere it is described, and the known gap is gone (RE198)" do
    relay_md = File.read!(Path.join(File.cwd!(), "relay.md"))
    domain = File.read!(Path.join(File.cwd!(), "docs/architecture/domain.md"))
    api = read("api.md")

    # The card exists to close this hole — the line that named it must not survive.
    refute relay_md =~ "known gap"

    assert relay_md =~ "./relay search"
    assert api =~ "./relay search"
    assert api =~ "q=<text>"
    assert domain =~ "./relay search"
    assert domain =~ "Cards.search/3"
  end

  test "authentication.md still explains the API key + env vars" do
    html = read("authentication.md")
    assert html =~ "RELAY_API_KEY"
    assert html =~ "Authorization: Bearer"
  end

  test "the runner and CLI pages describe the current runner, not the retired one" do
    # RLY-139: `relay watch` / `relay_config.json` / `relay pull` / `relay layout` are
    # deleted — the live public docs must not send an operator after them.
    runner = File.read!(Path.join(File.cwd!(), "docs/architecture/runner.md"))
    cli = read("cli.md")

    assert runner =~ "./relay start"
    assert runner =~ "is **deleted**", "runner.md must still record that the legacy runner is gone"

    refute cli =~ "./relay pull"
    refute cli =~ "./relay layout"
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
    paths = ["relay.md"] ++ Path.wildcard("priv/docs/*.md") ++ Path.wildcard("docs/**/*.md")

    for path <- paths, path != "docs/adr/0008-documentation-taxonomy.md" do
      refute File.read!(Path.join(File.cwd!(), path)) =~ "docs/agent-integration",
             "#{path} still links to the retired agent-integration page"
    end
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
                      no_runner) do
      assert api =~ verdict, "api.md should document the `#{verdict}` verdict"
    end
  end

  # RE93 — the expected author of a dependency graph is an agent, and an agent reads relay.md,
  # /docs/cli and /docs/api. A verb documented nowhere it looks ships dark.
  test "the dependency surface is documented everywhere an agent reads (RE93)" do
    relay_md = File.read!(Path.join(File.cwd!(), "relay.md"))
    cli = read("cli.md")
    api = read("api.md")

    for doc <- [relay_md, cli] do
      assert doc =~ "./relay depends"
      assert doc =~ "--depends-on"
    end

    for token <- ["depends_on", "\"blocks\"", "unknown_refs", "dependency_cycle"] do
      assert api =~ token, "api.md should document `#{token}`"
    end
  end

  test "cli.md lists every CLI verb RLY-177 added" do
    cli = read("cli.md")

    for verb <- ["./relay why", "./relay runs", "./relay runners", "./relay version", "--field"] do
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

  # RE318 — an agent reads relay.md and /docs/cli; a verb documented nowhere it looks ships dark.
  test "title, archive and unarchive are documented everywhere an agent reads (RE318)" do
    relay_md = File.read!(Path.join(File.cwd!(), "relay.md"))
    cli = read("cli.md")

    for doc <- [relay_md, cli], verb <- ["./relay title", "./relay archive", "unarchive"] do
      assert doc =~ verb, "expected `#{verb}` to be documented"
    end

    for doc <- [relay_md, cli] do
      assert doc =~ "cancel", "the archive row should say a live run must be cancelled first"
    end

    refute relay_md =~ "./relay rename"
    refute cli =~ "./relay rename"
  end

  test "the glossary defines Runner and notes that older mockups use the old word (RE319)" do
    glossary = File.read!(Path.join(File.cwd!(), "docs/glossary.md"))

    assert glossary =~ "- **Runner** —"
    assert glossary =~ "older mockups still use that word"
  end

  test "the runner page documents the hard cut's refusal and the renamed roster route (RE319)" do
    runner = File.read!(Path.join(File.cwd!(), "docs/architecture/runner.md"))
    api = read("api.md")

    assert runner =~ "predates the rename"
    assert runner =~ "`GET /api/runners`"
    assert api =~ "### GET /api/runners"
    assert api =~ "runner_outdated"
  end
end
