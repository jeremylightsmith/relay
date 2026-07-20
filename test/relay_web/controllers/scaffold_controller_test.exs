defmodule RelayWeb.ScaffoldControllerTest do
  use RelayWeb.ConnCase, async: true

  # The seven agent names the Code flow passes to `claude --agent`. A project missing
  # any one of these dies on its first agent node (RLY-181).
  @agents ~w(plan-implementer spec-reviewer quality-reviewer final-reviewer
             final-fixer smoke-tester acceptance-tester)

  describe "GET /api/scaffold" do
    test "is public — no Authorization header, still 200", %{conn: conn} do
      assert conn |> get(~p"/api/scaffold") |> json_response(200)
    end

    test "carries every allowlisted file with non-empty inline content", %{conn: conn} do
      body = conn |> get(~p"/api/scaffold") |> json_response(200)

      assert is_integer(body["cli_version"])
      assert body["cli_version"] > 0
      assert is_binary(body["scaffold_version"])
      refute body["scaffold_version"] == ""

      paths = Enum.map(body["files"], & &1["path"])

      for agent <- @agents do
        assert ".claude/agents/#{agent}.md" in paths
      end

      for skill <- ~w(brainstorm test-driven-development systematic-debugging
                      verification-before-completion receiving-code-review) do
        assert ".claude/skills/#{skill}/SKILL.md" in paths
      end

      assert ".claude/commands/write-plan.md" in paths
      assert ".relay/executor.json" in paths
      assert "AGENTS.md" in paths
      assert "CLAUDE.md" in paths

      for file <- body["files"] do
        assert file["mode"] == "644"
        refute file["content"] == "", "#{file["path"]} has empty content"
      end
    end

    test "does not ship Relay-only files to other projects", %{conn: conn} do
      body = conn |> get(~p"/api/scaffold") |> json_response(200)
      paths = Enum.map(body["files"], & &1["path"])

      refute ".claude/agents/rebaser.md" in paths
      refute ".claude/commands/worktree.md" in paths
      refute ".claude/commands/finish.md" in paths
      refute ".claude/skills/gen-problem/SKILL.md" in paths
      refute ".claude/skills/slicing-mockups/SKILL.md" in paths
      refute ".claude/skills/writing-skills/SKILL.md" in paths
    end

    test "the scaffolded executor.json parses and names a worktree namespace",
         %{conn: conn} do
      body = conn |> get(~p"/api/scaffold") |> json_response(200)
      entry = Enum.find(body["files"], &(&1["path"] == ".relay/executor.json"))

      assert {:ok, cfg} = Jason.decode(entry["content"])
      assert cfg["namespace"] == "exec"
      assert cfg["capacity"]["shared_clean"] == 3
      assert cfg["capacity"]["exclusive"] == 1
    end

    test "CLAUDE.md points at AGENTS.md", %{conn: conn} do
      body = conn |> get(~p"/api/scaffold") |> json_response(200)
      entry = Enum.find(body["files"], &(&1["path"] == "CLAUDE.md"))

      assert String.trim(entry["content"]) == "@AGENTS.md"
    end
  end

  describe "GET /install/relay" do
    test "serves the CLI verbatim with its version header", %{conn: conn} do
      conn = get(conn, ~p"/install/relay")
      body = response(conn, 200)

      assert body =~ "#!/usr/bin/env python3"
      assert body =~ ~r/^EXECUTOR_VERSION = \d+/m
      assert [version] = get_resp_header(conn, "x-relay-cli-version")
      assert String.to_integer(version) > 0
    end

    test "advertises the same version /api/scaffold does", %{conn: conn} do
      [header] = conn |> get(~p"/install/relay") |> get_resp_header("x-relay-cli-version")
      body = conn |> get(~p"/api/scaffold") |> json_response(200)

      assert String.to_integer(header) == body["cli_version"]
    end
  end

  describe "GET /install" do
    test "returns a bootstrap script pointing back at the requesting host",
         %{conn: conn} do
      body = conn |> get(~p"/install") |> response(200)

      assert body =~ "#!/bin/sh"
      assert body =~ "http://www.example.com/install/relay"
      assert body =~ "chmod +x bin/relay"
      assert body =~ "bin/relay init"
    end
  end
end
