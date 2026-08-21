defmodule Relay.DocsContentTest do
  use ExUnit.Case, async: true

  defp read(file), do: File.read!(Application.app_dir(:relay, "priv/docs/#{file}"))

  @expected [
    {"introduction.md", "# Introduction"},
    {"boards-and-stages.md", "# Boards & stages"},
    {"cards-and-handoffs.md", "# Cards & handoffs"},
    {"authentication.md", "# Authentication & API access"},
    {"cli.md", "# CLI (`bin/relay`)"},
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

  test "the CLI page documents the bin/relay command table" do
    html = read("cli.md")

    for cmd <- ["bin/relay board", "bin/relay card", "bin/relay move", "bin/relay needs-input", "bin/relay search"] do
      assert html =~ cmd, "cli.md should mention `#{cmd}`"
    end
  end

  test "card search is documented everywhere it is described, and the known gap is gone (RE198)" do
    relay_md = File.read!(Path.join(File.cwd!(), "relay.md"))
    domain = File.read!(Path.join(File.cwd!(), "docs/architecture/domain.md"))
    api = read("api.md")

    # The card exists to close this hole — the line that named it must not survive.
    refute relay_md =~ "known gap"

    assert relay_md =~ "bin/relay search"
    assert api =~ "bin/relay search"
    assert api =~ "q=<text>"
    assert domain =~ "bin/relay search"
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

    assert runner =~ "bin/relay execute"
    assert runner =~ "is **deleted**", "runner.md must still record that the legacy runner is gone"

    refute cli =~ "bin/relay pull"
    refute cli =~ "bin/relay layout"
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
          "GET /api/executors",
          "GET /api/version"
        ] do
      assert api =~ path, "api.md should document `#{path}`"
    end

    # The verdict vocabulary is the contract `relay why` prints — an undocumented verdict
    # is an operator staring at a word with no meaning.
    for verdict <- ~w(dispatchable blocked_by_dependencies no_enabled_flow awaiting_capacity
                      resume_refused wip_full owned_by_human blocked_on_input run_active
                      not_eligible run_failed job_stranded job_awaiting_slot executor_outdated
                      no_executor) do
      assert api =~ verdict, "api.md should document the `#{verdict}` verdict"
    end
  end

  test "cli.md lists every CLI verb RLY-177 added" do
    cli = read("cli.md")

    for verb <- ["bin/relay why", "bin/relay runs", "bin/relay executors", "bin/relay version", "--field"] do
      assert cli =~ verb, "cli.md should mention `#{verb}`"
    end
  end
end
