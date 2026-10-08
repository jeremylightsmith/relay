defmodule Relay.Config do
  @moduledoc """
  The one seam through which production code reads a config value a test needs to vary
  (ADR 0009 rule 1: a test never mutates global state).

  A test supplies its own value with `Process.put/2` under the same key; `get/2` and `git_sha/0`
  find it with `ProcessTree.get/2` — first in the calling process's dictionary, then its
  parent/`$ancestors`, then its `$callers` — so a `Task`, a `start_supervised!` child, or an
  engine process that re-seeded `$callers` (`Relay.Runs.Instance.adopt_callers/1`) all see the
  test's value, and no other test does. **In production nothing is ever put**, so every read
  falls through to the existing source — `Application.get_env(:relay, key, default)` or
  `System.get_env("GIT_SHA")` — and behavior is unchanged.

  Only the values tests actually vary are routed here: `:apple_client_ids`, `:runs_auto_start`
  and `:git_sha`. Boot-time reads stay plain `Application.get_env/3`.

  Two rules the lookup imposes:

    * **`cache: false`, always.** `ProcessTree`'s default copies a found value into the caller
      and every process it walked through, so a long-lived process would keep one test's value
      for every later test.
    * **`nil` means "not found".** `Process.put(:git_sha, nil)` would fall through to the real
      OS env, so "explicitly unset" is written as `false`; `git_sha/0` normalizes it to `nil`.
      `get/2` returns a found `false` as `false` (e.g. `:runs_auto_start`).
  """

  use Boundary, deps: []

  @doc "The value for `key`: a process-tree override, else `Application.get_env(:relay, key, default)`."
  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) when is_atom(key) do
    ProcessTree.get(key, cache: false, lazy_default: fn -> Application.get_env(:relay, key, default) end)
  end

  @doc "The build's git SHA: a `:git_sha` override (`false` = unset), else the `GIT_SHA` OS env var."
  @spec git_sha() :: String.t() | nil
  def git_sha do
    case ProcessTree.get(:git_sha, cache: false, lazy_default: fn -> System.get_env("GIT_SHA") end) do
      false -> nil
      sha -> sha
    end
  end
end
