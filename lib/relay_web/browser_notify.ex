defmodule RelayWeb.BrowserNotify do
  @moduledoc """
  `on_mount` hook (RE399) that relays the signed-in user's browser notifications to every open,
  non-embedded LiveView of theirs.

  `Relay.Push` decides what is push-worthy and broadcasts `{:browser_notification, message}` on
  the user's topic; this hook subscribes the LiveView process to it and forwards each message
  unchanged as `push_event "relay:notify"` to the `BrowserNotify` JS hook (`Layouts.app`
  renders its element). It also handles the hook's `"browser_notify:open"` event by navigating
  to `/board/:slug?card=:ref` — membership is enforced by `BoardLive`'s own mount.

  Wired into the `:require_authenticated` and `:admin` live_sessions. Nothing fires in `embed`
  (the native shell has APNs): `/cards/:ref` forces `embed: true` inside `BoardLive.mount`,
  after this hook ran, so the embed check happens again at delivery time.
  """
  use RelayWeb, :verified_routes

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, push_event: 3, push_navigate: 2]

  alias Relay.Push

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) and not embedded?(socket) do
      case socket.assigns[:current_scope] do
        %{user: %{id: user_id}} -> Push.subscribe_user(user_id)
        _signed_out -> :ok
      end
    end

    socket =
      socket
      |> attach_hook(:browser_notify, :handle_info, &handle_info/2)
      |> attach_hook(:browser_notify_open, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  defp handle_info({:browser_notification, message}, socket) do
    if embedded?(socket) do
      {:halt, socket}
    else
      {:halt, push_event(socket, "relay:notify", message)}
    end
  end

  defp handle_info(_other, socket), do: {:cont, socket}

  defp handle_event("browser_notify:open", %{"board_slug" => slug, "card_ref" => ref}, socket) do
    {:halt, push_navigate(socket, to: ~p"/board/#{slug}?#{[card: ref]}")}
  end

  # A malformed open event is ours to swallow — falling through would crash a LiveView that
  # has no handle_event clause for it.
  defp handle_event("browser_notify:open", _params, socket), do: {:halt, socket}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # `[:embed]`, not `.embed`: the :admin live_session has no `:mount_embed`, so the key is absent.
  defp embedded?(socket), do: socket.assigns[:embed] == true
end
