defmodule Relay.AgentIntegrationDocsTest do
  use ExUnit.Case, async: true

  @doc_path Path.join([File.cwd!(), "docs", "agent-integration.md"])

  test "the integration doc documents every mix relay subcommand" do
    doc = File.read!(@doc_path)

    for cmd <- ~w(board card pull comment move status needs-input own release) do
      assert doc =~ "mix relay #{cmd}", "agent-integration.md is missing `mix relay #{cmd}`"
    end

    assert doc =~ "RELAY_URL"
    assert doc =~ "RELAY_API_KEY"
    assert doc =~ "--json"
  end

  test "AGENTS.md links to the integration doc" do
    assert File.read!(Path.join(File.cwd!(), "AGENTS.md")) =~ "docs/agent-integration.md"
  end
end
