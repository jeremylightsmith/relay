defmodule Relay.Runs.PublishMarker do
  @moduledoc """
  The `.relay/published.json` marker: the ONE record of which `bin/relay` `EXECUTOR_VERSION` was
  last pushed to the public **relay-config** repo (RE185).

  The board must be able to name a version an executor can *really download*. This repo's
  `bin/relay` is routinely ahead of what was published (publishing is a manual step), so
  `EXECUTOR_VERSION` is the wrong answer, and `Relay.Runs.min_executor_version/0` is a floor
  ("below this, refuse work"), not a target. The marker is the only truthful source.

  It lives in one module so `Relay.Runs.latest_executor_version/0` (which reads it at compile
  time) and `Mix.Tasks.Relay.PublishConfig` (which writes it, and compares against it for
  `--check`) share one parser instead of two (AGENTS.md: a magic value is defined exactly once).
  """

  @rel_path ".relay/published.json"

  @doc "The marker's path relative to a project root."
  def rel_path, do: @rel_path

  @doc "The marker's absolute path inside `root`."
  def path(root), do: Path.join(root, @rel_path)

  @doc """
  The `executor_version` recorded at `path`, or `nil`.

  `nil` for every non-answer — no file, unreadable, not JSON, key missing, value not an integer.
  "Nothing has been published" and "the marker is broken" want the same, safe behaviour: the
  board advertises no fetchable version and no executor ever updates.
  """
  # `path` is never web/user input — it comes from `path/1` (this repo root or a test's
  # `tmp_dir`) or a Mix task argument, both trusted local operators, never a request.
  # sobelow_skip ["Traversal.FileModule"]
  def version(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"executor_version" => version}} <- Jason.decode(body),
         true <- is_integer(version) do
      version
    else
      _ -> nil
    end
  end

  @doc """
  Record `version` as published, at `path`, returning the path.

  One key and no timestamp on purpose: re-publishing the same version must be a no-op diff.
  """
  # `path` is never web/user input — see `version/1` above.
  # sobelow_skip ["Traversal.FileModule"]
  def write!(version, path) when is_integer(version) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(%{executor_version: version}, pretty: true) <> "\n")
    path
  end
end
