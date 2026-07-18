defmodule Relay.AgentIntegrationDocsTest do
  use ExUnit.Case, async: true

  @doc_path Path.join([File.cwd!(), "docs", "agent-integration.md"])

  test "the integration doc documents every bin/relay subcommand" do
    doc = File.read!(@doc_path)

    for cmd <-
          ~w(board card comment move status describe criteria needs-input own release approve reject sub-tasks check uncheck result) do
      assert doc =~ "bin/relay #{cmd}", "agent-integration.md is missing `bin/relay #{cmd}`"
    end

    assert doc =~ "RELAY_URL"
    assert doc =~ "RELAY_API_KEY"
    assert doc =~ "--json"
  end

  test "AGENTS.md links to the integration doc" do
    assert File.read!(Path.join(File.cwd!(), "AGENTS.md")) =~ "docs/agent-integration.md"
  end

  test "the Customizing section doesn't reference the retired relay_config.json action/{branch} schema" do
    # RLY-139: pipeline entries used to be `action: [{shell:...}|{claude:...}]`, rendered via
    # `render(template, vars)` with `{branch}` as a bare templating variable. That schema is
    # gone — a flow node has `run` + `vars` (see docs/designs/flows/code.jsonc's `branch` node).
    doc = File.read!(@doc_path)

    refute doc =~ "every `action`",
           "agent-integration.md still describes the retired relay_config.json `action` field"

    assert doc =~ "vars.branch",
           "the Customizing section should point at the current run/vars node model"

    assert doc =~ "code.jsonc",
           "the Customizing section should point at the Code flow's `branch` node for how the plan is materialized"
  end
end
