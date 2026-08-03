defmodule Mix.Tasks.Relay.PublishConfig do
  @shortdoc "Generate the public relay-config scaffold from this repo"

  @moduledoc """
  Populate the sibling `relay-config` repo — the public scaffold `bin/relay init` pulls over
  HTTPS — from this repo's source of truth. Copies `bin/relay`, `relay.md`, and the `.claude/`
  agents / commands / skills, then writes `manifest.json` (with `executor.version` pinned to
  `bin/relay`'s `EXECUTOR_VERSION`), `install.sh`, and the `CLAUDE.md`/`AGENTS.md` starters.

      mix relay.publish_config              # writes ../relay-config
      mix relay.publish_config /path/to/relay-config

  Idempotent — re-run whenever those sources change so the scaffold never drifts. It writes
  files only; committing and pushing `relay-config` stays a human step. Publishing also records
  the `bin/relay` `EXECUTOR_VERSION` it just wrote into this repo's `.relay/published.json`
  (RE185) — the marker `Relay.Runs.latest_executor_version/0` reads at compile time, so an
  executor never auto-updates to code relay-config does not actually serve yet.

      mix relay.publish_config --check          # non-zero exit if bin/relay is ahead of the marker
      mix relay.publish_config --check --warn   # same check, but only warns — never fails

  `--check` is a real gate (finish/merge time); `--check --warn` is the reminder wired into
  `mix precommit` so iterating on `bin/relay` is never blocked mid-branch.
  """

  use Mix.Task
  use Boundary, check: [in: false, out: false]

  alias Relay.Runs.PublishMarker

  @generated ~w(bin .claude starters .relay relay.md manifest.json)

  # Only what the shipped default flows (spec/plan/code) actually use ships in the public
  # scaffold — the dependency trace: Spec runs `/brainstorm`; Plan runs `/write-plan`; the Code
  # flow's 8 agents invoke `test-driven-development`, `verification-before-completion`,
  # `receiving-code-review`, and `systematic-debugging`. All 8 agents ship (each is a Code node);
  # other `.claude/` skills and commands are dev-only and are deliberately left out.
  @flow_skills ~w(brainstorm receiving-code-review systematic-debugging test-driven-development
                  verification-before-completion)
  @flow_commands ~w(write-plan)

  # Standalone tooling a scaffolded project wants even though no flow node invokes it —
  # `relay-doctor` checks a board's flow against this repo's factory, exactly what you reach for
  # after adding or renaming an agent; `relay-onboard` is the first-run loop that drives a fresh
  # repo to a green doctor; `writing-skills` ships because `relay-onboard` tells the human to
  # author a missing step with it, and a scaffold without it would dangle that instruction.
  @tooling_skills ~w(relay-doctor relay-onboard writing-skills)

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [check: :boolean, warn: :boolean])

    if opts[:check] do
      check(File.cwd!(), opts[:warn] || false)
    else
      publish(File.cwd!(), List.first(rest))
    end
  end

  @doc """
  Whether `bin/relay` is ahead of what was last published to relay-config.

  `{:ok, version}` when the source and `.relay/published.json` agree; `{:drift, source,
  published}` otherwise (`published` is `nil` when nothing has been published). ONE comparison
  behind all three callers — the task's own post-publish report, `--check`, and `--check --warn`.
  """
  def drift(src) do
    source = executor_version(src)
    published = PublishMarker.version(PublishMarker.path(src))

    if source == published, do: {:ok, source}, else: {:drift, source, published}
  end

  @doc """
  Report publish drift. Raises `Mix.Error` (non-zero exit) unless `warn?`, in which case it
  prints a banner and returns `:ok`.

  Two modes on purpose: `mix precommit` runs the warning form so iterating on `bin/relay` is
  never blocked, while the finish/merge-time `--check` is a real gate.
  """
  def check(src, warn?) do
    case drift(src) do
      {:ok, version} ->
        Mix.shell().info("relay-config: bin/relay and #{PublishMarker.rel_path()} agree at executor version #{version}.")

        :ok

      {:drift, source, published} ->
        message = drift_message(source, published)

        if warn? do
          Mix.shell().info("\n!! relay-config publish drift !!\n\n" <> message)
          :ok
        else
          Mix.raise(message)
        end
    end
  end

  defp drift_message(source, published) do
    """
    bin/relay is at EXECUTOR_VERSION #{source} but #{PublishMarker.rel_path()} records \
    #{published || "nothing published yet"}.

    Executors auto-update to what relay-config actually SERVES (RE185), so until this is
    published no executor can pick up the new code. To fix:

        mix relay.publish_config
        cd ../relay-config && git add -A && git commit -m "publish executor #{source}" && git push
        # then commit this repo's #{PublishMarker.rel_path()}
    """
  end

  defp publish(src, dst_arg) do
    dst = dst_arg || Path.expand("../relay-config", src)
    File.mkdir_p!(dst)

    # Clear only what we generate — leave .git, LICENSE, and a hand-edited README alone.
    for path <- @generated, do: File.rm_rf!(Path.join(dst, path))

    copy(src, dst, "bin/relay", 0o755)

    items =
      [
        item(
          "relay.md",
          "relay.md",
          "relay.md — agent guide",
          "How your agent drives Relay from Claude Code (the bin/relay CLI + REST API).",
          required: true
        ),
        starter(dst, "CLAUDE.md", "<!-- Instructions for Claude Code. Add yours above. -->\n"),
        starter(dst, "AGENTS.md", "<!-- Project instructions every coding agent reads. Add yours above. -->\n"),
        executor_config(dst)
      ] ++
        agents(src) ++ commands(src) ++ skills(src)

    for %{src: rel} = i <- items, i[:kind] != "starter" and rel != ".relay/executor.json" do
      copy(src, dst, rel)
    end

    version = executor_version(src)

    manifest =
      ordered([
        {"executor", ordered([{"version", version}])},
        {"items", Enum.map(items, &manifest_item/1)}
      ])

    write(dst, "manifest.json", Jason.encode!(manifest, pretty: true) <> "\n")
    write(dst, "install.sh", install_sh(), 0o755)
    maybe_write_readme(dst)

    req = Enum.count(items, & &1[:required])

    Mix.shell().info(
      "relay-config: #{length(items)} items (#{req} required, #{length(items) - req} optional) " <>
        "· executor.version #{version} → #{dst}"
    )

    PublishMarker.write!(version, PublishMarker.path(src))

    Mix.shell().info(
      "recorded executor version #{version} in #{PublishMarker.rel_path()} — commit it here, " <>
        "and commit + push #{dst}. Until both land, `mix relay.publish_config --check` reports drift."
    )
  end

  @doc "Skills that ship in the scaffold without any flow node naming them."
  def tooling_skills, do: @tooling_skills

  # ---- item builders ----

  defp item(src, dest, title, description, opts) do
    %{src: src, dest: dest, title: title, description: description}
    |> maybe_put(:required, opts[:required])
    |> maybe_put(:kind, opts[:kind])
  end

  defp starter(dst, dest, header) do
    write(dst, "starters/#{dest}", header <> "\n@relay.md\n")

    item("starters/#{dest}", dest, "#{dest} include", "Wires @relay.md in so agents read the Relay agent guide.",
      required: true,
      kind: "starter"
    )
  end

  defp executor_config(dst) do
    body =
      Jason.encode!(
        ordered([
          {"namespace", "exec"},
          {"capacity", ordered([{"shared_clean", 1}, {"exclusive", 1}])},
          {"poll_timeout", 25},
          {"heartbeat_interval", 15},
          {"max_retained_failed", 3},
          {"auto_update", true},
          {"auto_update_min_interval", 300}
        ]),
        pretty: true
      )

    write(dst, ".relay/executor.json", body <> "\n")

    item(
      ".relay/executor.json",
      ".relay/executor.json",
      "executor config",
      "How many jobs this machine runs at once and in which isolation class, " <>
        "and whether it updates bin/relay itself.",
      required: true
    )
  end

  defp agents(src) do
    for rel <- md_files(src, ".claude/agents") do
      {name, desc} = frontmatter(Path.join(src, rel))
      base = Path.basename(rel, ".md")
      item(rel, rel, "#{name || base} agent", desc || "Agent invoked by a flow node.", required: true)
    end
  end

  defp commands(src) do
    for rel <- md_files(src, ".claude/commands"),
        base = Path.basename(rel, ".md"),
        base in @flow_commands do
      item(rel, rel, "/#{base} command", "The #{base} slash command.", required: true)
    end
  end

  defp skills(src) do
    dir = Path.join(src, ".claude/skills")

    for skill <- ls_sorted(dir),
        skill in (@flow_skills ++ @tooling_skills),
        rel = ".claude/skills/#{skill}/SKILL.md",
        File.regular?(Path.join(src, rel)) do
      {name, desc} = frontmatter(Path.join(src, rel))
      item(rel, rel, "#{name || skill} skill", desc || "The #{skill} skill.", [])
    end
  end

  # ---- helpers ----

  defp md_files(src, dir) do
    src
    |> Path.join(dir)
    |> ls_sorted()
    |> Enum.filter(&String.ends_with?(&1, ".md"))
    |> Enum.map(&"#{dir}/#{&1}")
  end

  defp ls_sorted(dir), do: dir |> File.ls!() |> Enum.sort()

  defp copy(src, dst, rel, mode \\ 0o644) do
    to = Path.join(dst, rel)
    File.mkdir_p!(Path.dirname(to))
    File.cp!(Path.join(src, rel), to)
    File.chmod!(to, mode)
  end

  defp write(dst, rel, content, mode \\ 0o644) do
    to = Path.join(dst, rel)
    File.mkdir_p!(Path.dirname(to))
    File.write!(to, content)
    File.chmod!(to, mode)
    rel
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp ordered(pairs), do: Jason.OrderedObject.new(pairs)

  # Emit each manifest item with a stable key order so the generated file diffs cleanly.
  defp manifest_item(item) do
    ordered(
      [{"src", item.src}, {"dest", item.dest}, {"title", item.title}, {"description", item.description}] ++
        List.wrap(item[:required] && {"required", true}) ++
        List.wrap(item[:kind] && {"kind", item[:kind]})
    )
  end

  @doc "The `EXECUTOR_VERSION` declared by `src`'s `bin/relay`. The ONE regex parse of it."
  def executor_version(src) do
    [_, v] = Regex.run(~r/^EXECUTOR_VERSION\s*=\s*(\d+)/m, File.read!(Path.join(src, "bin/relay")))
    String.to_integer(v)
  end

  defp frontmatter(path) do
    case Regex.run(~r/\A---\n(.*?)\n---/s, File.read!(path)) do
      [_, block] ->
        {field(block, "name"), field(block, "description")}

      _ ->
        {nil, nil}
    end
  end

  defp field(block, key) do
    block
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [^key, value] -> String.trim(value)
        _ -> nil
      end
    end)
  end

  defp maybe_write_readme(dst) do
    path = Path.join(dst, "README.md")

    if !File.exists?(path) do
      File.write!(path, """
      # relay-config

      Public scaffold source for Relay. `bin/relay init` pulls `manifest.json` and every file it
      lists from here over plain HTTPS — no auth, no board key needed.

      **Generated** from the Relay repo by `mix relay.publish_config`. Don't hand-edit the copied
      files or `manifest.json`; re-run the task there instead.

          curl -fsSL https://raw.githubusercontent.com/jeremylightsmith/relay-config/main/install.sh | sh
          bin/relay init
      """)
    end
  end

  defp install_sh do
    """
    #!/bin/sh
    # Bootstrap the Relay CLI. Downloads bin/relay into the current project, then you run:
    #   bin/relay init
    set -e
    BASE="${RELAY_CONFIG_URL:-https://raw.githubusercontent.com/jeremylightsmith/relay-config/main}"
    mkdir -p bin
    echo "Downloading bin/relay from $BASE ..."
    curl -fsSL "$BASE/bin/relay" -o bin/relay
    chmod +x bin/relay
    echo "Installed ./bin/relay. Next, run it in a terminal:  bin/relay init"
    """
  end
end
