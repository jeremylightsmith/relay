defmodule RelayWeb.ScaffoldController do
  @moduledoc """
  The public bootstrap surface `relay init` reads (RLY-181).

  `GET /api/scaffold` returns ONE JSON document with the manifest and every file's
  content inline. That shape is deliberate: a `?path=` file-fetch endpoint would open a
  path-traversal surface to save ~60 KB, so no such parameter exists and the bug class
  cannot occur.

  The payload is read at compile time through the committed symlinks
  `priv/scaffold/claude -> ../../.claude` and `priv/scaffold/relay -> ../../bin/relay`
  (the same pattern `priv/docs/architecture -> ../../docs/architecture` uses), so the
  repo's real files stay the single source of truth — there is no copy step to keep in
  sync. `@external_resource` makes the content ship in releases and recompile on edit.
  """
  use RelayWeb, :controller

  @executor_json """
  {
    "namespace": "exec",
    "capacity": { "shared_clean": 3, "exclusive": 1 },
    "poll_timeout": 25,
    "heartbeat_interval": 15
  }
  """

  @agents_md """
  # Project conventions

  This file is read by every Relay flow node before it does anything. Replace this
  starter with your project's own conventions: what the app is, how to run it, how to
  run the tests, and the rules an agent must follow.

  ## Gate

  Every change must leave the project green. State the exact command here — the flows'
  reviewers and the plan's `Verification` section both read it:

      <your test / lint / build command>

  ## Layout

  Describe the directories an agent should know about, and any it must not touch.
  """

  @claude_md "@AGENTS.md\n"

  # {written path, source}. An explicit ALLOWLIST, never "everything under .claude/":
  # Relay-only files (the `rebaser` agent, the `worktree`/`finish` commands, and the
  # `gen-problem`/`slicing-mockups`/`writing-skills` skills) deliberately do not ship to
  # other projects. The `{:priv, rel}` entries are read through priv/scaffold/claude.
  #
  # The seven agents are the ones the Code flow names in `claude --agent <name>`; the
  # brainstorm skill and write-plan command are named by the Spec and Plan flows; the
  # remaining four skills are invoked BY those files, so omitting them would make the
  # scaffold degrade the first time a node reaches for one.
  @manifest [
    {".claude/agents/plan-implementer.md", {:priv, "claude/agents/plan-implementer.md"}},
    {".claude/agents/spec-reviewer.md", {:priv, "claude/agents/spec-reviewer.md"}},
    {".claude/agents/quality-reviewer.md", {:priv, "claude/agents/quality-reviewer.md"}},
    {".claude/agents/final-reviewer.md", {:priv, "claude/agents/final-reviewer.md"}},
    {".claude/agents/final-fixer.md", {:priv, "claude/agents/final-fixer.md"}},
    {".claude/agents/smoke-tester.md", {:priv, "claude/agents/smoke-tester.md"}},
    {".claude/agents/acceptance-tester.md", {:priv, "claude/agents/acceptance-tester.md"}},
    {".claude/skills/brainstorm/SKILL.md", {:priv, "claude/skills/brainstorm/SKILL.md"}},
    {".claude/skills/test-driven-development/SKILL.md", {:priv, "claude/skills/test-driven-development/SKILL.md"}},
    {".claude/skills/systematic-debugging/SKILL.md", {:priv, "claude/skills/systematic-debugging/SKILL.md"}},
    {".claude/skills/verification-before-completion/SKILL.md",
     {:priv, "claude/skills/verification-before-completion/SKILL.md"}},
    {".claude/skills/receiving-code-review/SKILL.md", {:priv, "claude/skills/receiving-code-review/SKILL.md"}},
    {".claude/commands/write-plan.md", {:priv, "claude/commands/write-plan.md"}},
    {".relay/executor.json", {:inline, @executor_json}},
    {"AGENTS.md", {:inline, @agents_md}},
    {"CLAUDE.md", {:inline, @claude_md}}
  ]

  for {_path, {:priv, rel}} <- @manifest do
    @external_resource Application.app_dir(:relay, "priv/scaffold/#{rel}")
  end

  @files (for {path, source} <- @manifest do
            content =
              case source do
                {:priv, rel} ->
                  File.read!(Application.app_dir(:relay, "priv/scaffold/#{rel}"))

                {:inline, text} ->
                  text
              end

            %{path: path, mode: "644", content: content}
          end)

  @cli_path Application.app_dir(:relay, "priv/scaffold/relay")
  @external_resource @cli_path
  @cli_source File.read!(@cli_path)

  # The CLI's own VERSION constant is the single source of truth for `cli_version`;
  # parsing it here means the two can never drift. A missing constant fails the build.
  @cli_version (case Regex.run(~r/^VERSION = (\d+)/m, @cli_source) do
                  [_, v] -> String.to_integer(v)
                  nil -> raise "bin/relay has no `VERSION = <int>` constant (RLY-181)"
                end)

  # Evaluated at compile time, so Mix is available; the value is baked into the release.
  @scaffold_version Mix.Project.config()[:version]

  def scaffold(conn, _params) do
    json(conn, %{
      scaffold_version: @scaffold_version,
      cli_version: @cli_version,
      files: @files
    })
  end

  def cli(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("x-relay-cli-version", to_string(@cli_version))
    |> send_resp(200, @cli_source)
  end

  def install(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, install_script(base_url(conn)))
  end

  # The host comes from the request itself, so a script fetched from a host always
  # points back at THAT host — no configured base URL to get wrong per deployment.
  defp base_url(conn) do
    port =
      if {conn.scheme, conn.port} in [{:http, 80}, {:https, 443}],
        do: "",
        else: ":#{conn.port}"

    "#{conn.scheme}://#{conn.host}#{port}"
  end

  defp install_script(base) do
    """
    #!/bin/sh
    # relay bootstrap (RLY-181) — drops bin/relay into this directory and scaffolds it.
    # Usage: curl -fsSL #{base}/install | sh
    set -eu
    RELAY_URL="${RELAY_URL:-#{base}}"
    mkdir -p bin
    curl -fsSL "#{base}/install/relay" -o bin/relay
    chmod +x bin/relay
    RELAY_URL="$RELAY_URL" bin/relay init
    """
  end
end
