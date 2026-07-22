defmodule Relay.AgentIntegrationDocsTest do
  use ExUnit.Case, async: true

  @doc_path Path.join(File.cwd!(), "relay.md")

  test "relay.md documents every bin/relay subcommand" do
    doc = File.read!(@doc_path)

    for cmd <-
          ~w(board card comment move status describe criteria needs-input own release approve reject sub-tasks check uncheck result) do
      assert doc =~ "bin/relay #{cmd}", "relay.md is missing `bin/relay #{cmd}`"
    end

    assert doc =~ "RELAY_URL"
    assert doc =~ "RELAY_API_KEY"
    assert doc =~ "--json"
  end

  test "relay.md carries the RELAY_NODE_SCRATCH-contract anchor the scaffolded skills deep-link to" do
    # The brainstorm skill and write-plan command link to relay.md#the-relay_node_scratch-contract;
    # GitHub derives that slug from this exact heading, so it must stay verbatim.
    assert File.read!(@doc_path) =~ "### The `RELAY_NODE_SCRATCH` contract"
  end

  test "AGENTS.md links to relay.md" do
    assert File.read!(Path.join(File.cwd!(), "AGENTS.md")) =~ "relay.md"
  end

  test "the Customizing section doesn't reference the retired relay_config.json action/{branch} schema" do
    doc = File.read!(@doc_path)

    refute doc =~ "every `action`",
           "relay.md still describes the retired relay_config.json `action` field"

    assert doc =~ "vars.branch",
           "the Customizing section should point at the current run/vars node model"

    assert doc =~ "code.jsonc",
           "the Customizing section should point at the Code flow's `branch` node"
  end
end
