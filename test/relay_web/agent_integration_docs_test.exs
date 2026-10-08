defmodule Relay.AgentIntegrationDocsTest do
  use ExUnit.Case, async: true

  @doc_path Path.join(File.cwd!(), "relay.md")

  test "relay.md documents every ./relay subcommand" do
    doc = File.read!(@doc_path)

    for cmd <-
          ~w(board card comment move status describe criteria needs-input own release approve reject sub-tasks check uncheck tasks task result) do
      assert doc =~ "./relay #{cmd}", "relay.md is missing `./relay #{cmd}`"
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

  test "relay.md stays the short guide and points at the public docs for the rest" do
    doc = File.read!(@doc_path)

    assert doc =~ "$RELAY_URL/docs/cli"
    refute doc =~ "every `action`", "relay.md still describes the retired relay_config.json `action` field"
    # relay.md ships into every consuming repo, so it must not carry this repo's deploy steps.
    refute doc =~ "bin/deploy_"
    refute doc =~ "ship_to_main"
  end

  test "the CLI page's Flows-as-data section describes the current run/vars node model" do
    cli = File.read!(Path.join(File.cwd!(), "priv/docs/cli.md"))

    assert cli =~ "vars.branch"
    assert cli =~ "code.json"
  end
end
