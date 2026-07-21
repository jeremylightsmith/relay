defmodule Relay.DocsContentTest do
  use ExUnit.Case, async: true

  defp read(file), do: File.read!(Application.app_dir(:relay, "priv/docs/#{file}"))

  @expected [
    {"introduction.md", "# Introduction"},
    {"boards-and-stages.md", "# Boards & stages"},
    {"cards-and-handoffs.md", "# Cards & handoffs"},
    {"authentication.md", "# Authentication & API access"},
    {"cli.md", "# CLI (`bin/relay`)"},
    {"agent-integration.md", "# Agent integration"},
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

    for cmd <- ["bin/relay board", "bin/relay card", "bin/relay move", "bin/relay needs-input"] do
      assert html =~ cmd, "cli.md should mention `#{cmd}`"
    end
  end

  test "authentication.md still explains the API key + env vars" do
    html = read("authentication.md")
    assert html =~ "RELAY_API_KEY"
    assert html =~ "Authorization: Bearer"
  end

  test "the agent-integration and CLI pages describe the current runner, not the retired one" do
    # RLY-139: `relay watch` / `relay_config.json` / `relay pull` / `relay layout` are
    # deleted — the live public docs must not send an operator after them.
    agent_integration = read("agent-integration.md")
    cli = read("cli.md")

    assert agent_integration =~ "bin/relay execute"
    refute agent_integration =~ "relay watch"
    refute agent_integration =~ "relay_config.json"

    refute cli =~ "bin/relay pull"
    refute cli =~ "bin/relay layout"
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
    for verdict <- ~w(dispatchable no_enabled_flow awaiting_capacity wip_full owned_by_human
                      blocked_on_input run_active not_eligible run_failed job_stranded
                      executor_outdated no_executor) do
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
