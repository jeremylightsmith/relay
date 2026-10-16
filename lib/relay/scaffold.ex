defmodule Relay.Scaffold do
  @moduledoc """
  The five Relay-owned files the board serves at `/api/scaffold`, and the build that produces
  them (RE304, ADR 0010).

  These files are Relay's, never a user's: a project's `./relay`, the `relay-*` skills under
  `skill_dir/0`, and `relay.md`. (A fourth, setup skill was retired by RE443 for the board's setup wizard and
  its install command.) That is what lets `./relay update` overwrite them unconditionally — no
  provenance ledger, no per-file diff prompt.

  `relay.md` joined the set after RE304 (see ADR 0010's amendment). It is the agent-facing guide
  to driving a card — the CLI verbs, the node/outcome contract, the `RELAY_NODE_SCRATCH` rule —
  and it is entirely generic, with nothing repo-specific in it. Leaving it undistributed meant
  every project's copy froze at whatever `/relay-onboard` first wrote and silently rotted away
  from the runner it describes.

  **The version is derived, never maintained.** It is the first 12 hex characters of the
  sha256 of the sorted `"<path>:<sha256>"` lines, so it changes exactly when content changes,
  requires no stored state, and cannot be forgotten. Clients only ever compare it for
  equality; "you are N versions behind" is deliberately not supported.

  `priv/scaffold/` is a build artifact: written by `mix relay.build_scaffold` (run by
  `mix setup`, by the `test` alias, and by the `Dockerfile` before `mix release`) and
  gitignored. Every read here is a runtime read, because a Mix release ships `priv/` but
  ships neither `relay` nor `.claude/`.

  **The served `relay` carries its board's URL (RE443).** The committed file has a placeholder
  `BOARD_URL = ""` line; `fetch("relay", board_url: url)` bakes the serving board's URL into it
  so a project needs no `RELAY_URL`. `manifest(board_url: url)` describes those served bytes:
  the `relay` item's `sha256`/`bytes` are the BAKED copy's — every runner up to v89 checks a
  download with a raw sha256 against that field, so it must match what is served — and its
  `unbaked_sha256` is the built placeholder copy's, which `./relay` v90+ compares against with
  the line reset (`runner_sha256`). The version stays derived from the built (unbaked) shas, so
  it is one value per build on every board. The line is masked out of the runner's fingerprint,
  so baking it changes nothing the version guard sees.
  """

  use Boundary, deps: []

  # The manifest's canonical skill directory (RE457) — the ONE Elixir definition of the literal.
  # A project on another LLM keeps its skills elsewhere; `items/1` maps to that directory.
  @skill_dir ".claude/skills"

  # The ONE definition of what is Relay-owned. Sorted, because the version derivation and the
  # manifest ordering both depend on a stable order and this is where that order is decided.
  @items [
    "#{@skill_dir}/relay-doctor/SKILL.md",
    "#{@skill_dir}/relay-onboard/SKILL.md",
    "#{@skill_dir}/relay-update/SKILL.md",
    "relay",
    "relay.md"
  ]

  @manifest_name "manifest.json"

  @version_length 12

  # The ONE regex parse of `RUNNER_VERSION`, mirroring ./relay's own RUNNER_VERSION_RE.
  @runner_version_re ~r/^RUNNER_VERSION\s*=\s*(\d+)/m

  @runner_path "relay"

  # The ONE Elixir parse of ./relay's `BOARD_URL` line (RE443), mirroring ./relay's BOARD_URL_RE.
  # The value is a JSON string literal on one line; the runner contract fixture pins the two.
  @board_url_re ~r/^BOARD_URL\s*=[ \t]*.*$/m

  @doc "The Relay-owned paths, sorted. Nothing else is ever served or updated."
  @spec items() :: [String.t()]
  def items, do: @items

  @doc ~S(The manifest's canonical skill directory, `".claude/skills"`: every skill item lives under it.)
  @spec skill_dir() :: String.t()
  def skill_dir, do: @skill_dir

  @doc """
  `items/0` with every skill item moved from `skill_dir/0` to `dir`, in `items/0`'s order; every
  other path unchanged. The served manifest never changes — this is the project-side view of it.
  """
  @spec items(String.t()) :: [String.t()]
  def items(dir) when is_binary(dir) do
    prefix = @skill_dir <> "/"

    Enum.map(@items, fn
      ^prefix <> rest -> dir <> "/" <> rest
      path -> path
    end)
  end

  @doc "Where the built scaffold lives inside the running app."
  @spec root() :: String.t()
  def root, do: Application.app_dir(:relay, "priv/scaffold")

  @doc """
  The served manifest, or `:error` when the scaffold has not been built.

  `:error` rather than a raise: a dev box that has not run `mix setup` should get a clean
  503 from the controller, not a 500.

  With `board_url:` (RE443) the `relay` item describes the copy `fetch/2` serves with that
  option: `sha256` and `bytes` are the baked bytes', and `unbaked_sha256` is the built
  placeholder copy's. Without it every item is exactly as built. `version` never changes.
  """
  # `root()` and `@manifest_name` are both fixed, never request input.
  # sobelow_skip ["Traversal.FileModule"]
  @spec manifest(keyword()) :: {:ok, map()} | :error
  def manifest(opts \\ []) do
    with {:ok, body} <- File.read(Path.join(root(), @manifest_name)),
         {:ok, %{"version" => v, "items" => items} = manifest} when is_binary(v) and is_list(items) <-
           Jason.decode(body) do
      describe_served(manifest, Keyword.get(opts, :board_url))
    else
      _ -> :error
    end
  end

  defp describe_served(manifest, nil), do: {:ok, manifest}

  defp describe_served(%{"items" => items} = manifest, url) when is_binary(url) do
    case fetch(@runner_path, board_url: url) do
      {:ok, served} ->
        {:ok, %{manifest | "items" => Enum.map(items, &describe_runner(&1, served))}}

      :error ->
        :error
    end
  end

  defp describe_runner(%{"path" => @runner_path, "sha256" => built} = item, served) do
    Map.merge(item, %{"sha256" => sha256(served), "bytes" => byte_size(served), "unbaked_sha256" => built})
  end

  defp describe_runner(item, _served), do: item

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  @doc """
  The bytes of one served file, or `:error`.

  `path` is checked against `items/0` — a static allowlist — **before** it reaches the
  filesystem, so this is not a general file server and traversal is impossible by construction
  rather than by sanitising.

  The one option, `board_url:`, bakes that URL into the `BOARD_URL` line of `relay` (RE443) —
  every other item ignores it, and without it the bytes are exactly what was built.
  """
  # `path` is matched against the @items literal list above before any read; a value that is
  # not one of those five strings never reaches File.read/1.
  # sobelow_skip ["Traversal.FileModule"]
  @spec fetch(String.t(), keyword()) :: {:ok, binary()} | :error
  def fetch(path, opts \\ []) when is_binary(path) do
    with true <- path in @items,
         {:ok, body} <- File.read(Path.join(root(), path)) do
      {:ok, maybe_bake(path, body, Keyword.get(opts, :board_url))}
    else
      _ -> :error
    end
  end

  defp maybe_bake(@runner_path, body, url) when is_binary(url), do: bake_board_url(body, url)
  defp maybe_bake(_path, body, _url), do: body

  @doc """
  `source` with its `BOARD_URL` line set to `url` (RE443). A source with no such line is
  returned unchanged; `""` resets it to the placeholder.
  """
  @spec bake_board_url(binary(), String.t()) :: binary()
  def bake_board_url(source, url) when is_binary(source) and is_binary(url) do
    Regex.replace(@board_url_re, source, fn _ -> board_url_line(url) end, global: false)
  end

  @doc ~S"""
  The `BOARD_URL` line for `url`: `BOARD_URL = "<url>"`, the value JSON-encoded so it is a
  valid Python string literal whatever it contains.
  """
  @spec board_url_line(String.t()) :: String.t()
  def board_url_line(url) when is_binary(url), do: "BOARD_URL = " <> Jason.encode!(url)

  @doc """
  The `RUNNER_VERSION` of the `./relay` this app actually serves, or `nil`.

  This is what `Relay.Runs.latest_runner_version/0` answers with. It is truthful by
  construction — the served bytes and the advertised number cannot disagree, which is exactly
  what the retired `.relay/published.json` marker existed to paper over.
  """
  @spec runner_version() :: integer() | nil
  def runner_version do
    case fetch(@runner_path) do
      {:ok, source} -> parse_runner_version(source)
      :error -> nil
    end
  end

  @doc "The `RUNNER_VERSION` a `./relay` source declares, or `nil`. The ONE parse of it."
  @spec parse_runner_version(binary()) :: integer() | nil
  def parse_runner_version(source) do
    case Regex.run(@runner_version_re, source) do
      [_, v] -> String.to_integer(v)
      _ -> nil
    end
  end

  @doc """
  The derived version for `[{path, sha256}]`. First 12 hex of the sha256 of the sorted
  `"<path>:<sha256>"` lines. The ONE definition of the rule.
  """
  @spec version([{String.t(), String.t()}]) :: String.t()
  def version(entries) do
    entries
    |> Enum.map(fn {path, sha} -> "#{path}:#{sha}" end)
    |> Enum.sort()
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @version_length)
  end

  @doc """
  Copy every item from `src_root` into `dest_root` and write the manifest. Returns it.

  `dest_root` is cleared first, so an item removed from `items/0` cannot linger and keep being
  served. A missing source raises — a scaffold quietly short one skill is worse than a failed
  build.
  """
  # Both roots are local operator input (a Mix task's cwd or a test's tmp_dir), never a request.
  # sobelow_skip ["Traversal.FileModule"]
  @spec build!(String.t(), String.t()) :: map()
  def build!(src_root, dest_root) do
    File.rm_rf!(dest_root)

    items =
      for rel <- @items do
        content = File.read!(Path.join(src_root, rel))
        to = Path.join(dest_root, rel)
        File.mkdir_p!(Path.dirname(to))
        File.write!(to, content)

        %{
          "path" => rel,
          "sha256" => sha256(content),
          "bytes" => byte_size(content)
        }
      end

    manifest = %{
      "version" => version(Enum.map(items, &{&1["path"], &1["sha256"]})),
      "items" => items
    }

    File.write!(Path.join(dest_root, @manifest_name), Jason.encode!(manifest, pretty: true) <> "\n")

    manifest
  end
end
