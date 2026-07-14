defmodule RelayWeb.Api.AllController do
  @moduledoc """
  The native app's cross-board decision surface (RLY-80): the aggregated needs-you feed
  the inbox renders, plus the human's approve/reject/answer actions. Authenticated by
  `RelayWeb.ApiUserAuth` (user bearer token), acting as `{:user, id}` — never as the agent.
  """

  use RelayWeb, :controller

  alias Relay.Cards
  alias RelayWeb.Api.FeedJSON

  action_fallback RelayWeb.Api.FallbackController

  def feed(conn, _params) do
    rows = Cards.needs_you_feed(conn.assigns.current_user)

    conn
    |> put_view(json: FeedJSON)
    |> render(:feed, rows: rows)
  end
end
