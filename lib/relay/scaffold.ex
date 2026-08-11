defmodule Relay.Scaffold do
  @moduledoc """
  The five Relay-owned files the board serves at `/api/scaffold`, and the build that produces
  them (RE304, ADR 0010).

  These files are Relay's, never a user's: a project's `bin/relay` and its four `relay-*`
  skills. That is what lets `bin/relay update` overwrite them unconditionally — no provenance
  ledger, no per-file diff prompt.

  **The version is derived, never maintained.** It is the first 12 hex characters of the
  sha256 of the sorted `"<path>:<sha256>"` lines, so it changes exactly when content changes,
  requires no stored state, and cannot be forgotten. Clients only ever compare it for
  equality; "you are N versions behind" is deliberately not supported.

  `priv/scaffold/` is a build artifact: written by `mix relay.build_scaffold` (run by
  `mix setup`, by the `test` alias, and by the `Dockerfile` before `mix release`) and
  gitignored. Every read here is a runtime read, because a Mix release ships `priv/` but
  ships neither `bin/` nor `.claude/`.
  """

  use Boundary, deps: []

  # The ONE definition of what is Relay-owned. Sorted, because the version derivation and the
  # manifest ordering both depend on a stable order and this is where that order is decided.
  @items [
    ".claude/skills/relay-doctor/SKILL.md",
    ".claude/skills/relay-onboard/SKILL.md",
    ".claude/skills/relay-setup/SKILL.md",
    ".claude/skills/relay-update/SKILL.md",
    "bin/relay"
  ]

  @manifest_name "manifest.json"

  @version_length 12

  # The ONE regex parse of `EXECUTOR_VERSION`, mirroring bin/relay's own EXECUTOR_VERSION_RE.
  @executor_version_re ~r/^EXECUTOR_VERSION\s*=\s*(\d+)/m

  @executor_path "bin/relay"

  @doc "The Relay-owned paths, sorted. Nothing else is ever served or updated."
  @spec items() :: [String.t()]
  def items, do: @items

  @doc "Where the built scaffold lives inside the running app."
  @spec root() :: String.t()
  def root, do: Application.app_dir(:relay, "priv/scaffold")

  @doc """
  The served manifest, or `:error` when the scaffold has not been built.

  `:error` rather than a raise: a dev box that has not run `mix setup` should get a clean
  503 from the controller, not a 500.
  """
  # `root()` and `@manifest_name` are both fixed, never request input.
  # sobelow_skip ["Traversal.FileModule"]
  @spec manifest() :: {:ok, map()} | :error
  def manifest do
    with {:ok, body} <- File.read(Path.join(root(), @manifest_name)),
         {:ok, %{"version" => v, "items" => items} = manifest} when is_binary(v) and is_list(items) <-
           Jason.decode(body) do
      {:ok, manifest}
    else
      _ -> :error
    end
  end

  @doc """
  The bytes of one served file, or `:error`.

  `path` is checked against `items/0` — a static allowlist — **before** it reaches the
  filesystem, so this is not a general file server and traversal is impossible by construction
  rather than by sanitising.
  """
  # `path` is matched against the @items literal list above before any read; a value that is
  # not one of those five strings never reaches File.read/1.
  # sobelow_skip ["Traversal.FileModule"]
  @spec fetch(String.t()) :: {:ok, binary()} | :error
  def fetch(path) when is_binary(path) do
    if path in @items do
      case File.read(Path.join(root(), path)) do
        {:ok, body} -> {:ok, body}
        {:error, _} -> :error
      end
    else
      :error
    end
  end

  @doc """
  The `EXECUTOR_VERSION` of the `bin/relay` this app actually serves, or `nil`.

  This is what `Relay.Runs.latest_executor_version/0` answers with. It is truthful by
  construction — the served bytes and the advertised number cannot disagree, which is exactly
  what the retired `.relay/published.json` marker existed to paper over.
  """
  @spec executor_version() :: integer() | nil
  def executor_version do
    case fetch(@executor_path) do
      {:ok, source} -> parse_executor_version(source)
      :error -> nil
    end
  end

  @doc "The `EXECUTOR_VERSION` a `bin/relay` source declares, or `nil`. The ONE parse of it."
  @spec parse_executor_version(binary()) :: integer() | nil
  def parse_executor_version(source) do
    case Regex.run(@executor_version_re, source) do
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
          "sha256" => :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower),
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
