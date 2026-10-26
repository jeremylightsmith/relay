defmodule Hamaca.Scaffold do
  @moduledoc """
  The Hamaca-owned files the board serves at `/api/scaffold`, in two layouts, and the build that
  produces them (RE304, ADR 0010, RE478).

  These files are Hamaca's, never a user's: a project's runner, the skills under `skill_dir/0`,
  and the agent guide. (A fourth, setup skill was retired by RE443 for the board's setup wizard
  and its install command.) That is what lets an update overwrite them unconditionally — no
  provenance ledger, no per-file diff prompt.

  **Two layouts, one source (RE478).** The repo's sources are Hamaca-named — `hamaca` (the full
  runner), `hamaca.md`, the `hamaca-*` skills — plus the `relay` shim and three thin `relay-*`
  alias skills that exist only for the relay → hamaca compatibility window. One table per layout
  maps each served path to its source and a transform:

    * `legacy` — what a request with no `layout` param gets, i.e. every installed v≤93
      `./relay`: `relay` is the FULL runner (same bytes as `hamaca`), and `relay.md` and the
      `relay-*` skills are complete copies generated from the hamaca sources by
      `to_legacy_names/1`. Never the shim or an alias — an old runner verifies the runner it
      downloads by its `RUNNER_VERSION` line and writes skill paths verbatim.
    * `hamaca` — `?layout=hamaca`: the runner at `hamaca`, `hamaca.md`, the `hamaca-*` skills,
      and the shim and aliases (`alias_items/0`) served as they are.

  `hamaca.md` is the agent-facing guide to driving a card — the CLI verbs, the node/outcome
  contract, the `HAMACA_NODE_SCRATCH` rule — and it is entirely generic, with nothing
  repo-specific in it, which is why it is distributed (ADR 0010's amendment).

  **The version is derived, never maintained.** Per layout, it is the first 12 hex characters of
  the sha256 of the sorted `"<path>:<sha256>"` lines, so it changes exactly when that layout's
  content changes, requires no stored state, and cannot be forgotten. Clients only ever compare
  it for equality, and only against the same layout; "you are N versions behind" is
  deliberately not supported.

  `priv/scaffold/<layout>/` is a build artifact: written by `mix hamaca.build_scaffold` (run by
  `mix setup`, by the `test` alias, and by the `Dockerfile` before `mix release`) and
  gitignored. Every read here is a runtime read, because a Mix release ships `priv/` but
  ships neither the runner nor `.claude/`.

  **The served runner carries its board's URL (RE443).** The committed file has a placeholder
  `BOARD_URL = ""` line; `fetch(runner_path(layout), layout: layout, board_url: url)` bakes the
  serving board's URL into it so a project needs no `RELAY_URL`. `manifest(board_url: url)`
  describes those served bytes: the runner item's `sha256`/`bytes` are the BAKED copy's — every
  runner up to v89 checks a download with a raw sha256 against that field, so it must match
  what is served — and its `unbaked_sha256` is the built placeholder copy's, which v90+
  compares against with the line reset (`runner_sha256`). The version stays derived from the
  built (unbaked) shas, so it is one value per build on every board. The line is masked out of
  the runner's fingerprint, so baking it changes nothing the version guard sees.
  """

  use Boundary, deps: []

  # The manifest's canonical skill directory (RE457) — the ONE Elixir definition of the literal.
  # A project on another LLM keeps its skills elsewhere; `local_items/2` maps to that directory.
  @skill_dir ".claude/skills"

  # The ONE definition of the layout vocabulary (RE478). Pinned in the runner contract fixture.
  @layouts ["hamaca", "legacy"]
  @default_layout "legacy"
  @layout_param "layout"

  # Each layout's runner item: the one entry baked with BOARD_URL and given an unbaked_sha256.
  @runner_paths %{"hamaca" => "hamaca", "legacy" => "relay"}

  # The ONE swap list that turns a Hamaca-named source into its legacy (./relay) copy, applied
  # in order. Only these literal tokens move: `{relay}`, `~/.relay`, `.relay-retained` and the
  # word "Hamaca" in prose never match.
  @legacy_names [
    {"./hamaca", "./relay"},
    {".hamaca/", ".relay/"},
    {"hamaca.md", "relay.md"},
    {"HAMACA_", "RELAY_"},
    {"hamaca-doctor", "relay-doctor"},
    {"hamaca-onboard", "relay-onboard"},
    {"hamaca-update", "relay-update"}
  ]

  # The ONE definition of what each layout serves: `{served_path, source_path, transform}`, where
  # the transform is `:as_is` or `:legacy_names` (`to_legacy_names/1`). Sorted by served path,
  # because the version derivation and the manifest ordering both depend on a stable order and
  # this is where that order is decided.
  @layout_table %{
    "legacy" => [
      {"#{@skill_dir}/relay-doctor/SKILL.md", "#{@skill_dir}/hamaca-doctor/SKILL.md", :legacy_names},
      {"#{@skill_dir}/relay-onboard/SKILL.md", "#{@skill_dir}/hamaca-onboard/SKILL.md", :legacy_names},
      {"#{@skill_dir}/relay-update/SKILL.md", "#{@skill_dir}/hamaca-update/SKILL.md", :legacy_names},
      {"relay", "hamaca", :as_is},
      {"relay.md", "hamaca.md", :legacy_names}
    ],
    "hamaca" => [
      {"#{@skill_dir}/hamaca-doctor/SKILL.md", "#{@skill_dir}/hamaca-doctor/SKILL.md", :as_is},
      {"#{@skill_dir}/hamaca-onboard/SKILL.md", "#{@skill_dir}/hamaca-onboard/SKILL.md", :as_is},
      {"#{@skill_dir}/hamaca-update/SKILL.md", "#{@skill_dir}/hamaca-update/SKILL.md", :as_is},
      {"#{@skill_dir}/relay-doctor/SKILL.md", "#{@skill_dir}/relay-doctor/SKILL.md", :as_is},
      {"#{@skill_dir}/relay-onboard/SKILL.md", "#{@skill_dir}/relay-onboard/SKILL.md", :as_is},
      {"#{@skill_dir}/relay-update/SKILL.md", "#{@skill_dir}/relay-update/SKILL.md", :as_is},
      {"hamaca", "hamaca", :as_is},
      {"hamaca.md", "hamaca.md", :as_is},
      {"relay", "relay", :as_is}
    ]
  }

  # The hamaca-layout entries that exist only for the relay -> hamaca compatibility window
  # (removed by RE482): the ./relay shim and the thin relay-* alias skills.
  @alias_items [
    "#{@skill_dir}/relay-doctor/SKILL.md",
    "#{@skill_dir}/relay-onboard/SKILL.md",
    "#{@skill_dir}/relay-update/SKILL.md",
    "relay"
  ]

  @items Map.new(@layout_table, fn {layout, rows} -> {layout, Enum.map(rows, &elem(&1, 0))} end)

  @sources @layout_table |> Map.values() |> List.flatten() |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

  @manifest_name "manifest.json"

  @version_length 12

  # The ONE regex parse of `RUNNER_VERSION`, mirroring the runner's own RUNNER_VERSION_RE.
  @runner_version_re ~r/^RUNNER_VERSION\s*=\s*(\d+)/m

  # The ONE Elixir parse of the runner's `BOARD_URL` line (RE443), mirroring its BOARD_URL_RE.
  # The value is a JSON string literal on one line; the runner contract fixture pins the two.
  @board_url_re ~r/^BOARD_URL\s*=[ \t]*.*$/m

  @doc ~S(The scaffold layouts, `["hamaca", "legacy"]`. The ONE definition of the closed set.)
  @spec layouts() :: [String.t()]
  def layouts, do: @layouts

  @doc ~S(The layout a request with no `layout` param gets: `"legacy"`, what every v≤93 runner reads.)
  @spec default_layout() :: String.t()
  def default_layout, do: @default_layout

  @doc ~S(The query-param name that picks a layout on `/api/scaffold`: `"layout"`.)
  @spec layout_param() :: String.t()
  def layout_param, do: @layout_param

  @doc ~S(The runner item's path in `layout`: `"hamaca"` for `"hamaca"`, `"relay"` for `"legacy"`.)
  @spec runner_path(String.t()) :: String.t()
  def runner_path(layout), do: Map.fetch!(@runner_paths, layout)

  @doc "The paths `layout` serves, sorted. Nothing else is ever served or updated."
  @spec items(String.t()) :: [String.t()]
  def items(layout), do: Map.fetch!(@items, layout)

  @doc """
  The hamaca-layout paths that exist only for the compatibility window: the `relay` shim and the
  three `relay-*` alias skills.
  """
  @spec alias_items() :: [String.t()]
  def alias_items, do: @alias_items

  @doc """
  `items(layout)` with every skill path moved from `skill_dir/0` to `skill_dir`, in order; every
  other path unchanged. The served manifest never changes — this is the project-side view of it.
  """
  @spec local_items(String.t(), String.t()) :: [String.t()]
  def local_items(layout, skill_dir) when is_binary(skill_dir), do: layout |> items() |> localize(skill_dir)

  @doc """
  The Hamaca-named files a project keeps under `skill_dir` — `local_items("hamaca", skill_dir)`
  without `alias_items/0`. What the setup wizard lists; never the shim or an alias.
  """
  @spec primary_items(String.t()) :: [String.t()]
  def primary_items(skill_dir) when is_binary(skill_dir), do: localize(items("hamaca") -- @alias_items, skill_dir)

  defp localize(paths, skill_dir) do
    prefix = @skill_dir <> "/"

    Enum.map(paths, fn
      ^prefix <> rest -> skill_dir <> "/" <> rest
      path -> path
    end)
  end

  @doc """
  The distinct repo source paths every layout is built from — what the `Dockerfile` must COPY
  before `mix hamaca.build_scaffold`.
  """
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc """
  `source` with the Hamaca names swapped back to the legacy ones (`./hamaca` → `./relay`,
  `.hamaca/` → `.relay/`, `hamaca.md` → `relay.md`, `HAMACA_` → `RELAY_`, `hamaca-doctor|
  onboard|update` → `relay-…`), in that order. How the legacy layout's guide and skills are made.
  """
  @spec to_legacy_names(binary()) :: binary()
  def to_legacy_names(source) when is_binary(source) do
    Enum.reduce(@legacy_names, source, fn {from, to}, acc -> String.replace(acc, from, to) end)
  end

  @doc ~S(The manifest's canonical skill directory, `".claude/skills"`: every skill item lives under it.)
  @spec skill_dir() :: String.t()
  def skill_dir, do: @skill_dir

  @doc "Where the built scaffold lives inside the running app."
  @spec root() :: String.t()
  def root, do: Application.app_dir(:hamaca, "priv/scaffold")

  @doc """
  The served manifest of a layout, or `:error` when the scaffold has not been built or the
  layout is not one of `layouts/0`.

  `:error` rather than a raise: a dev box that has not run `mix setup` should get a clean
  503 from the controller, not a 500.

  Options: `layout:` (default `default_layout/0`) and `board_url:` (RE443) — with it the
  layout's runner item describes the copy `fetch/2` serves with that option: `sha256` and
  `bytes` are the baked bytes', and `unbaked_sha256` is the built placeholder copy's. Without it
  every item is exactly as built. `version` never changes.
  """
  # The path is `root()`, a layout checked against the @layouts literal list, and
  # `@manifest_name` — never free request input.
  # sobelow_skip ["Traversal.FileModule"]
  @spec manifest(keyword()) :: {:ok, map()} | :error
  def manifest(opts \\ []) do
    layout = Keyword.get(opts, :layout, @default_layout)

    with true <- layout in @layouts,
         {:ok, body} <- File.read(Path.join([root(), layout, @manifest_name])),
         {:ok, %{"version" => v, "items" => items} = manifest} when is_binary(v) and is_list(items) <-
           Jason.decode(body) do
      describe_served(manifest, layout, Keyword.get(opts, :board_url))
    else
      _ -> :error
    end
  end

  defp describe_served(manifest, _layout, nil), do: {:ok, manifest}

  defp describe_served(%{"items" => items} = manifest, layout, url) when is_binary(url) do
    runner = runner_path(layout)

    case fetch(runner, layout: layout, board_url: url) do
      {:ok, served} ->
        {:ok, %{manifest | "items" => Enum.map(items, &describe_runner(&1, runner, served))}}

      :error ->
        :error
    end
  end

  defp describe_runner(%{"path" => runner, "sha256" => built} = item, runner, served) do
    Map.merge(item, %{"sha256" => sha256(served), "bytes" => byte_size(served), "unbaked_sha256" => built})
  end

  defp describe_runner(item, _runner, _served), do: item

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  @doc """
  The bytes of one served file, or `:error`.

  `layout` is checked against `layouts/0` and `path` against `items(layout)` — static
  allowlists — **before** either reaches the filesystem, so this is not a general file server
  and traversal is impossible by construction rather than by sanitising. A path of the other
  layout is `:error` too.

  Options: `layout:` (default `default_layout/0`) and `board_url:`, which bakes that URL into
  the `BOARD_URL` line of the layout's runner item (RE443) — every other item ignores it, and
  without it the bytes are exactly what was built.
  """
  # `layout` is matched against the @layouts literal list and `path` against that layout's
  # @items literal list before any read; a value that is not one of those strings never reaches
  # File.read/1.
  # sobelow_skip ["Traversal.FileModule"]
  @spec fetch(String.t(), keyword()) :: {:ok, binary()} | :error
  def fetch(path, opts \\ []) when is_binary(path) do
    layout = Keyword.get(opts, :layout, @default_layout)

    with true <- layout in @layouts,
         true <- path in items(layout),
         {:ok, body} <- File.read(Path.join([root(), layout, path])) do
      {:ok, maybe_bake(path == runner_path(layout), body, Keyword.get(opts, :board_url))}
    else
      _ -> :error
    end
  end

  defp maybe_bake(true, body, url) when is_binary(url), do: bake_board_url(body, url)
  defp maybe_bake(_runner?, body, _url), do: body

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
  The `RUNNER_VERSION` of the runner this app actually serves, or `nil`. Read from the hamaca
  layout's runner — the same bytes the legacy layout serves at `relay`.

  This is what `Hamaca.Runs.latest_runner_version/0` answers with. It is truthful by
  construction — the served bytes and the advertised number cannot disagree, which is exactly
  what the retired `.relay/published.json` marker existed to paper over.
  """
  @spec runner_version() :: integer() | nil
  def runner_version do
    case fetch(runner_path("hamaca"), layout: "hamaca") do
      {:ok, source} -> parse_runner_version(source)
      :error -> nil
    end
  end

  @doc "The `RUNNER_VERSION` a runner source declares, or `nil`. The ONE parse of it."
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
  Build every layout from the sources under `src_root` into `dest_root/<layout>/`, each with its
  `manifest.json`. Returns `%{layout => manifest}`.

  `dest_root` is cleared first, so an item removed from a layout (or the pre-RE478 flat build)
  cannot linger and keep being served. A missing source raises — a scaffold quietly short one
  skill is worse than a failed build.
  """
  # Both roots are local operator input (a Mix task's cwd or a test's tmp_dir), never a request.
  # sobelow_skip ["Traversal.FileModule"]
  @spec build!(String.t(), String.t()) :: %{String.t() => map()}
  def build!(src_root, dest_root) do
    File.rm_rf!(dest_root)

    Map.new(@layouts, fn layout -> {layout, build_layout!(layout, src_root, Path.join(dest_root, layout))} end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp build_layout!(layout, src_root, dest) do
    items =
      for {served, source, transform} <- Map.fetch!(@layout_table, layout) do
        content = src_root |> Path.join(source) |> File.read!() |> transform(transform)
        to = Path.join(dest, served)
        File.mkdir_p!(Path.dirname(to))
        File.write!(to, content)

        %{
          "path" => served,
          "sha256" => sha256(content),
          "bytes" => byte_size(content)
        }
      end

    manifest = %{
      "version" => version(Enum.map(items, &{&1["path"], &1["sha256"]})),
      "items" => items
    }

    File.write!(Path.join(dest, @manifest_name), Jason.encode!(manifest, pretty: true) <> "\n")

    manifest
  end

  defp transform(content, :as_is), do: content
  defp transform(content, :legacy_names), do: to_legacy_names(content)
end
