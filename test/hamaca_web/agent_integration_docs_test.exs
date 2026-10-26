defmodule Hamaca.AgentIntegrationDocsTest do
  use ExUnit.Case, async: true

  @doc_path Path.join(File.cwd!(), "hamaca.md")

  test "hamaca.md documents every ./hamaca subcommand" do
    doc = File.read!(@doc_path)

    for cmd <-
          ~w(board card comment move status describe criteria needs-input own release approve reject sub-tasks check uncheck tasks task result) do
      assert doc =~ "./hamaca #{cmd}", "hamaca.md is missing `./hamaca #{cmd}`"
    end

    assert doc =~ "HAMACA_URL"
    assert doc =~ "HAMACA_API_KEY"
    assert doc =~ "--json"
  end

  test "the guide carries the NODE_SCRATCH-contract anchor the scaffolded skills deep-link to" do
    # The write-plan command links to hamaca.md#the-hamaca_node_scratch-contract (scaffolded
    # repos still on the legacy names link to relay.md#the-relay_node_scratch-contract);
    # GitHub derives that slug from this exact heading, so it must stay verbatim in the legacy
    # relay.md the scaffold generates from hamaca.md (RE478).
    assert File.read!(@doc_path) =~ "### The `HAMACA_NODE_SCRATCH` contract"
    assert Hamaca.Scaffold.to_legacy_names(File.read!(@doc_path)) =~ "### The `RELAY_NODE_SCRATCH` contract"
  end

  test "AGENTS.md links to hamaca.md" do
    assert File.read!(Path.join(File.cwd!(), "AGENTS.md")) =~ "[`hamaca.md`](hamaca.md)"
  end

  test "hamaca.md stays the short guide and points at the public docs for the rest" do
    doc = File.read!(@doc_path)

    assert doc =~ "$HAMACA_URL/docs/cli"
    refute doc =~ "every `action`", "hamaca.md still describes the retired relay_config.json `action` field"
    # hamaca.md ships into every consuming repo, so it must not carry this repo's deploy steps.
    refute doc =~ "bin/deploy_"
    refute doc =~ "ship_to_main"
  end

  test "the CLI page's Flows-as-data section describes the current run/vars node model" do
    cli = File.read!(Path.join(File.cwd!(), "priv/docs/cli.md"))

    assert cli =~ "vars.branch"
    assert cli =~ "code.json"
  end
end
