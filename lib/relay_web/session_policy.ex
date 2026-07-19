defmodule RelayWeb.SessionPolicy do
  @moduledoc """
  The one place the session-lifetime numbers live (RLY-127).

  `RelayWeb.Endpoint` reads `max_age/0` for the `_relay_key` cookie attribute and
  `RelayWeb.Auth` reads both to enforce the same window server-side. The cookie's
  `max_age` is only a client-side hint — `Plug.Session.COOKIE.get/3` does no age
  check, so a client can replay an arbitrarily old cookie — which is exactly why
  the two must not drift.

  Deliberately dependency-free: the endpoint reads this from the `@session_options`
  module attribute, so it must compile first.
  """

  @max_age 60 * 60 * 24 * 7
  @refresh_after 60 * 60 * 24

  @doc "How long a session lives without use, in seconds — 7 days, sliding."
  def max_age, do: @max_age

  @doc """
  How stale a session's `:session_refreshed_at` stamp must be before we re-stamp
  it, in seconds — one day.

  Re-stamping is a session write and a write puts a `Set-Cookie` on the response,
  so it is throttled. One day is the right granularity for a 7-day window, and it
  mirrors the existing throttle idiom in `Relay.Accounts`
  (`@user_token_last_used_throttle_seconds`).
  """
  def refresh_after, do: @refresh_after
end
