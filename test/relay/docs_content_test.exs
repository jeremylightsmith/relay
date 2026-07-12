defmodule Relay.DocsContentTest do
  use ExUnit.Case, async: true

  defp read(file), do: File.read!(Application.app_dir(:relay, "priv/docs/#{file}"))

  @expected [
    {"introduction.md", "# Introduction"},
    {"boards-and-stages.md", "# Boards & stages"},
    {"cards-and-handoffs.md", "# Cards & handoffs"},
    {"setup.md", "# Setup"},
    {"cli.md", "# CLI (`bin/relay`)"},
    {"agent-integration.md", "# Agent integration"},
    {"api.md", "# API Reference"}
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

  test "setup.md still explains the API key + env vars" do
    html = read("setup.md")
    assert html =~ "RELAY_API_KEY"
    assert html =~ "Authorization: Bearer"
  end
end
