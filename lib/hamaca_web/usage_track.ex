defmodule HamacaWeb.UsageTrack do
  @moduledoc """
  `on_mount` hook (RE475) that touches the signed-in user's visit on `Hamaca.Usage.Tracker`: on the
  connected mount, on every `handle_params` (where it reads the board — the hook runs before the
  LiveView's own `mount`, so `:board` is only assigned by then), and on every `handle_event`.
  The dead render is the `HamacaWeb.Plugs.UsageTrack` plug's job, so nothing is touched or attached
  until the socket is connected.

  The card ref comes from the route or query params only — `"ref"` in `:card` mode (`/cards/:ref`),
  `"card"` otherwise (`?card=<ref>`) — and only when it is a binary: an event's `"card"` param is
  often a form map. Events touch with the board alone. Wired into the `:require_authenticated` and
  `:admin` live_sessions; never blocks or fails the view (`Hamaca.Usage.Tracker.touch/3` is a cast).
  """

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Hamaca.Usage.Tracker

  def on_mount(:default, params, _session, socket) do
    if connected?(socket) do
      Tracker.touch(user(socket), %{card_ref: card_ref(params)})

      socket =
        socket
        |> attach_hook(:usage_track_params, :handle_params, &handle_params/3)
        |> attach_hook(:usage_track_event, :handle_event, &handle_event/3)

      {:cont, socket}
    else
      {:cont, socket}
    end
  end

  defp handle_params(params, _uri, socket) do
    Tracker.touch(user(socket), %{board_id: board_id(socket), card_ref: card_ref(params)})
    {:cont, socket}
  end

  defp handle_event(_event, _params, socket) do
    Tracker.touch(user(socket), %{board_id: board_id(socket)})
    {:cont, socket}
  end

  defp user(socket) do
    case socket.assigns[:current_scope] do
      %{user: user} -> user
      _signed_out -> nil
    end
  end

  # Other views may assign something else under `:board`.
  defp board_id(socket) do
    case socket.assigns[:board] do
      %Schemas.Board{id: id} -> id
      _none -> nil
    end
  end

  defp card_ref(%{"ref" => ref}) when is_binary(ref), do: ref
  defp card_ref(%{"card" => ref}) when is_binary(ref), do: ref
  defp card_ref(_params), do: nil
end
