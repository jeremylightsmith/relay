defmodule RelayWeb.Feedback do
  @moduledoc """
  The "Suggest an idea" URL (RE397) — Relay's public roadmap, where signed-in users
  suggest or upvote ideas. Set by `RELAY_FEEDBACK_URL` (`config/runtime.exs`); unset or
  blank means `nil`, and every surface hides the item, so a self-hosted or dev install
  never shows a dead link.

  This module is the **only** reader of `:relay, :feedback_url`: the web account menu
  (`RelayWeb.Layouts.app/1`) and the native auth success body
  (`RelayWeb.NativeAuthController`) both go through it.

  `url/1` exists for ADR 0009 rule 1 (`docs/adr/0009-test-isolation.md`): the app env is
  a boot-time-only read that no test mutates — the rule's sanctioned exception — so tests
  never `Application.put_env/3` it. Instead a caller's assigns may carry an explicit
  `:feedback_url` key, which wins over the app env (even when `nil`).
  """

  @doc "A binary that is non-blank after trimming, returned unchanged; anything else is `nil`."
  @spec normalize(term()) :: String.t() | nil
  def normalize(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  def normalize(_value), do: nil

  @doc "The configured feedback URL, or `nil` when unset or blank."
  @spec url() :: String.t() | nil
  def url, do: normalize(Application.get_env(:relay, :feedback_url))

  @doc """
  The feedback URL for an assigns map (a component's `assigns` or a `conn.assigns`): an
  explicit `:feedback_url` key wins, even when `nil`; otherwise falls back to `url/0`.
  """
  @spec url(map()) :: String.t() | nil
  def url(%{feedback_url: value}), do: normalize(value)
  def url(assigns) when is_map(assigns), do: url()
end
