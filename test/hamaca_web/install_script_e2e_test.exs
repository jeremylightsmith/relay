defmodule HamacaWeb.InstallScriptE2ETest do
  @moduledoc """
  RE443 scenarios 11–14: the rendered install script, run for real with `sh` against the test
  endpoint, in a temp git repo whose `PATH` holds only the tools the script may use.

  `async: false` puts the sandbox in shared mode, so the requests the spawned `curl` makes reach
  this test's data. `HOME`, git's global config and `TMPDIR` all point into the temp dir, and the
  developer's real `claude` / `codex` are never on the script's `PATH`.
  """
  use HamacaWeb.ConnCase, async: false

  alias Hamaca.Boards
  alias Hamaca.Setup
  alias HamacaWeb.InstallScript

  @moduletag :tmp_dir

  # The script's whole toolbox (besides sh builtins), per the RE443 install contract.
  @tools ~w(curl git python3 uname mktemp mkdir chmod mv rm cat grep printf)

  @ignores [".claude/worktrees/", "/tmp/", ".envrc.local"]

  # RE457: every Hamaca-owned file `./relay update` lays down, skills under the LLM's skill dir.
  @codex_files ~w(.agents/skills/relay-onboard/SKILL.md .agents/skills/relay-update/SKILL.md
                  .agents/skills/relay-doctor/SKILL.md relay relay.md .relay/scaffold.json)
  @claude_files ~w(.claude/skills/relay-onboard/SKILL.md .claude/skills/relay-update/SKILL.md
                   .claude/skills/relay-doctor/SKILL.md relay relay.md .relay/scaffold.json)

  setup %{tmp_dir: tmp} = tags do
    home = Path.join(tmp, "home")
    tmpdir = Path.join(tmp, "tmp")
    bin = Path.join(tmp, "bin")
    for dir <- [home, tmpdir, bin], do: File.mkdir_p!(dir)

    for tool <- @tools, do: File.ln_s!(real_executable(tool), Path.join(bin, tool))

    git_env = [
      {"HOME", home},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_AUTHOR_NAME", "Test"},
      {"GIT_AUTHOR_EMAIL", "test@example.com"},
      {"GIT_COMMITTER_NAME", "Test"},
      {"GIT_COMMITTER_EMAIL", "test@example.com"}
    ]

    origin = Path.join(tmp, "origin.git")
    repo = Path.join(tmp, "streaks")
    File.mkdir_p!(repo)

    git!(tmp, git_env, ["init", "-q", "--bare", "-b", "main", origin])
    git!(repo, git_env, ["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, "README.md"), "# Streaks\n")
    git!(repo, git_env, ["add", "README.md"])
    git!(repo, git_env, ["commit", "-q", "-m", "init"])
    git!(repo, git_env, ["remote", "add", "origin", origin])
    git!(repo, git_env, ["push", "-q", "-u", "origin", "main"])
    git!(repo, git_env, ["remote", "set-head", "origin", "main"])

    user = insert(:user)

    {:ok, board} =
      Boards.create_board(user, %{name: "Streaks", slug: unique_slug("streaks"), template: "bare-minimum"})

    {:ok, %{token: token}} = Setup.choose_llm(board, user, Map.get(tags, :llm, "codex"))
    {:ok, {_ip, port}} = HamacaWeb.Endpoint.server_info(:http)
    base = "http://127.0.0.1:#{port}"

    script = Path.join(tmp, "install.sh")
    File.write!(script, InstallScript.render(base, board.slug))

    env =
      git_env ++
        [{"PATH", bin}, {"TMPDIR", tmpdir}, {"RELAY_URL", nil}, {"RELAY_API_KEY", token}, {"PYTHONPATH", nil}]

    %{
      board: board,
      user: user,
      token: token,
      repo: repo,
      bin: bin,
      base: base,
      script: script,
      env: env,
      git_env: git_env
    }
  end

  # Scenario 11
  test "with the LLM's CLI missing: exit 1, the fix printed, nothing written, step 4 failed", ctx do
    {out, status} = run_script(ctx)

    assert status == 1, out
    assert out =~ "!!  codex on PATH"
    assert out =~ "npm install -g @openai/codex"
    assert git_status(ctx) == ""
    refute File.exists?(Path.join(ctx.repo, "relay"))
    assert step(ctx.board, "3").status == :done
    assert step(ctx.board, "4").status == :failed
  end

  # RE457 scenario 1 (acceptance criterion 2)
  test "a Codex install lays down every Hamaca file under .agents/skills via ./relay update", ctx do
    stub_cli!(ctx, "codex")

    {out, status} = run_script(ctx)

    assert status == 0, out
    for rel <- @codex_files, do: assert(File.exists?(Path.join(ctx.repo, rel)), "#{rel} missing\n#{out}")
    refute File.exists?(Path.join(ctx.repo, ".claude/skills"))

    assert %{"skill_dir" => ".agents/skills", "pointer_file" => "AGENTS.md", "base" => "origin/main"} =
             decode_commented_json!(file(ctx, ".relay/runner.json"))

    assert count_lines(file(ctx, "AGENTS.md"), Setup.pointer_line()) == 1
    assert out =~ "  .agents/skills/relay-update/SKILL.md"
  end

  # RE457 scenario 2
  test "after a Codex install the project reports current", ctx do
    stub_cli!(ctx, "codex")
    {out, 0} = run_script(ctx)

    {check_out, status} = update_check(ctx)

    assert status == 0, out <> check_out
    assert %{"current" => true, "local_version" => version} = decode_report!(check_out)
    assert is_binary(version)
  end

  # RE457 scenario 3 (acceptance criterion 1)
  @tag llm: "claude-code"
  test "a Claude install lays down every Hamaca file under .claude/skills and reports current", ctx do
    stub_cli!(ctx, "claude")

    {out, status} = run_script(ctx)

    assert status == 0, out
    for rel <- @claude_files, do: assert(File.exists?(Path.join(ctx.repo, rel)), "#{rel} missing\n#{out}")
    assert count_lines(file(ctx, "CLAUDE.md"), Setup.pointer_line()) == 1
    assert %{"skill_dir" => ".claude/skills"} = decode_commented_json!(file(ctx, ".relay/runner.json"))

    {check_out, 0} = update_check(ctx)
    assert %{"current" => true, "local_version" => version} = decode_report!(check_out)
    assert is_binary(version)

    assert out |> String.trim_trailing() |> String.ends_with?("Next: open claude here and run /relay-onboard")
  end

  # RE457 scenario 4
  test "the installed report lists every file once, relay first", ctx do
    stub_cli!(ctx, "codex")

    {out, 0} = run_script(ctx)

    four = step(ctx.board, "4")
    files = four.data["files"]
    assert ["relay" | _] = files, out

    for rel <-
          ~w(.agents/skills/relay-onboard/SKILL.md .agents/skills/relay-update/SKILL.md
             .agents/skills/relay-doctor/SKILL.md relay.md AGENTS.md .relay/runner.json
             .relay/prepare-worktree.sh .gitignore),
        do: assert(rel in files, "#{rel} not in #{inspect(files)}")

    assert files == Enum.uniq(files)
    assert four.status == :done
    assert step(ctx.board, "5").status == :active
  end

  # Scenario 12
  test "with the CLI present: writes the Hamaca files, never the key, and ticks step 4", ctx do
    stub_cli!(ctx, "codex")

    {out, status} = run_script(ctx)

    assert status == 0, out
    relay = file(ctx, "relay")
    assert relay =~ ~r/^#{Regex.escape(~s(BOARD_URL = "#{HamacaWeb.Endpoint.url()}"))}$/m
    assert executable?(ctx, "relay")

    assert File.exists?(Path.join(ctx.repo, ".agents/skills/relay-onboard/SKILL.md"))
    assert File.exists?(Path.join(ctx.repo, "relay.md"))
    assert count_lines(file(ctx, "AGENTS.md"), Setup.pointer_line()) == 1
    assert %{"base" => "origin/main"} = decode_commented_json!(file(ctx, ".relay/runner.json"))
    assert executable?(ctx, ".relay/prepare-worktree.sh")

    gitignore = file(ctx, ".gitignore")
    for entry <- @ignores, do: assert(count_lines(gitignore, entry) == 1)

    for path <- Path.wildcard(Path.join(ctx.repo, "**"), match_dot: true), File.regular?(path) do
      refute File.read!(path) =~ ctx.token, "#{path} contains the key"
    end

    assert out |> String.trim_trailing() |> String.ends_with?("Next: open codex here and run /relay-onboard")
    assert out =~ "Hamaca install for board Streaks · default LLM: Codex"
    assert step(ctx.board, "4").status == :done
    assert step(ctx.board, "5").status == :active
  end

  # Scenario 13
  test "a second run duplicates no line and keeps an edited runner.json", ctx do
    stub_cli!(ctx, "codex")
    {out, 0} = run_script(ctx)

    runner_json = Path.join(ctx.repo, ".relay/runner.json")
    edited = String.replace(File.read!(runner_json), "origin/main", "origin/edited")
    File.write!(runner_json, edited)

    {out2, status} = run_script(ctx)

    assert status == 0, out <> out2
    assert File.read!(runner_json) == edited
    assert count_lines(file(ctx, "AGENTS.md"), Setup.pointer_line()) == 1

    gitignore = file(ctx, ".gitignore")
    for entry <- @ignores, do: assert(count_lines(gitignore, entry) == 1)
    assert out2 =~ ".gitignore (+0 lines)"
  end

  # Scenario 14
  test "a key from another board: exit 1, the board's message, nothing written", ctx do
    other_user = insert(:user)

    {:ok, other} =
      Boards.create_board(other_user, %{name: "Other", slug: unique_slug("other"), template: "bare-minimum"})

    {:ok, %{token: other_token}} = Setup.choose_llm(other, other_user, "codex")
    stub_cli!(ctx, "codex")

    {out, status} = run_script(%{ctx | env: List.keystore(ctx.env, "RELAY_API_KEY", 0, {"RELAY_API_KEY", other_token})})

    assert status == 1, out
    assert out =~ "this key belongs to a different board"
    assert git_status(ctx) == ""
  end

  test "a repo path with quotes and backslashes reaches the board intact", ctx do
    awkward = Path.join(Path.dirname(ctx.repo), ~S(str"e\aks))
    File.rename!(ctx.repo, awkward)

    {out, status} = run_script(%{ctx | repo: awkward})

    assert status == 1, out
    four = step(ctx.board, "4")
    assert four.status == :failed
    assert %{"ok" => true, "detail" => detail} = Enum.find(four.data["checks"], &(&1["id"] == "git_repo"))
    assert String.ends_with?(detail, ~S(/str"e\aks))
  end

  test "RELAY_API_KEY unset: exit 1 without calling the board", ctx do
    {out, status} = run_script(%{ctx | env: List.keystore(ctx.env, "RELAY_API_KEY", 0, {"RELAY_API_KEY", nil})})

    assert status == 1
    assert out =~ "RELAY_API_KEY is not set — copy the export line from step 3 of the setup wizard."
    assert step(ctx.board, "3").status == :active
  end

  defp run_script(ctx) do
    System.cmd(System.find_executable("sh"), [ctx.script], cd: ctx.repo, env: ctx.env, stderr_to_stdout: true)
  end

  defp stub_cli!(ctx, name) do
    cli = Path.join(ctx.bin, name)
    File.write!(cli, "#!/bin/sh\necho '#{name} 0.0.0-test'\n")
    File.chmod!(cli, 0o755)
  end

  defp update_check(ctx) do
    System.cmd(Path.join(ctx.bin, "python3"), ["./relay", "update", "--check", "--json"],
      cd: ctx.repo,
      env: List.keystore(ctx.env, "RELAY_URL", 0, {"RELAY_URL", ctx.base}),
      stderr_to_stdout: true
    )
  end

  # `./relay` logs `[relay] …` to stdout, so the report starts at the first `{` line.
  defp decode_report!(out) do
    out
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
    |> Enum.join("\n")
    |> Jason.decode!()
  end

  defp git!(dir, env, args) do
    {out, 0} = System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true)
    out
  end

  defp git_status(ctx), do: git!(ctx.repo, ctx.git_env, ["status", "--porcelain"])

  defp file(ctx, rel), do: File.read!(Path.join(ctx.repo, rel))

  defp executable?(ctx, rel), do: Bitwise.band(File.stat!(Path.join(ctx.repo, rel)).mode, 0o111) != 0

  # The starter runner.json carries whole-line `//` comments.
  defp decode_commented_json!(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "//"))
    |> Enum.join("\n")
    |> Jason.decode!()
  end

  defp count_lines(text, line), do: text |> String.split("\n") |> Enum.count(&(&1 == line))

  defp step(board, id), do: board |> Setup.checklist() |> Map.fetch!(:steps) |> Enum.find(&(&1.id == id))

  # The real binary, not a version-manager shim: a shim would need the developer's HOME and PATH.
  defp real_executable("python3") do
    {path, 0} = System.cmd(System.find_executable("python3"), ["-c", "import sys; print(sys.executable)"])
    String.trim(path)
  end

  defp real_executable(tool), do: System.find_executable(tool) || flunk("#{tool} is not on PATH")
end
