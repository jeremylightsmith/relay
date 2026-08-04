defmodule RelayWeb.TimeAgo do
  @moduledoc """
  The one relative-time ladder the web layer renders: `just now` / `Nm ago` /
  `Nh ago` / `Nd ago`.

  RE277 extracted this from two byte-identical private copies — `RunComponents.ago/2`
  and `BoardsLive.updated_label/1` — so the card drawer's Notes timestamps became a
  third *caller* rather than a third copy. Behaviour is unchanged from those copies.
  """

  @doc """
  Formats `at` relative to now. See `ago/2`.
  """
  def ago(at), do: ago(DateTime.utc_now(), at)

  @doc """
  Formats `at` relative to `now`.

  `nil` renders as an empty string. A future `at` clamps to `just now`: callers pass
  server timestamps, and clock skew must never render `-3m ago`.
  """
  def ago(_now, nil), do: ""

  def ago(%DateTime{} = now, %DateTime{} = at) do
    seconds = max(DateTime.diff(now, at, :second), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end
end
