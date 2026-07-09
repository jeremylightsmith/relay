defmodule Relay.AgentIntegrationDocsTest do
  use ExUnit.Case, async: true

  @doc_path Path.join([File.cwd!(), "docs", "agent-integration.md"])

  test "the integration doc documents every bin/relay subcommand" do
    doc = File.read!(@doc_path)

    for cmd <- ~w(board card pull comment move status describe needs-input own release approve reject) do
      assert doc =~ "bin/relay #{cmd}", "agent-integration.md is missing `bin/relay #{cmd}`"
    end

    assert doc =~ "RELAY_URL"
    assert doc =~ "RELAY_API_KEY"
    assert doc =~ "--json"
  end

  test "AGENTS.md links to the integration doc" do
    assert File.read!(Path.join(File.cwd!(), "AGENTS.md")) =~ "docs/agent-integration.md"
  end
end
