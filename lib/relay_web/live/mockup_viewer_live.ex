defmodule RelayWeb.MockupViewerLive do
  @moduledoc """
  The legacy RE370 mockup link, `/attachments/:id/view` (`RelayWeb.attachment_view_path/1`).

  RE380 made the mockup viewer a mode of `RelayWeb.BoardLive` — the card's drawer URL plus
  `mockup=<attachment id>`, opened in the same tab with the card as a left sheet. This route
  exists only so RE370-era links (in comments, notes, chat) keep working: it redirects a member to
  `/board/:slug?card=<ref>&mockup=<id>` and renders nothing of its own.

  Membership-scoped through `Relay.Attachments.get_attachment/2`; an unknown id, a board the user
  can't see, or a non-HTML attachment all 404 — never leak the difference.
  """
  use RelayWeb, :live_view

  alias Relay.Attachments
  alias Relay.Cards
  alias Schemas.Attachment

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Attachments.get_attachment(socket.assigns.current_scope.user, id) do
      %Attachment{card: %Schemas.Card{board: board} = card} = attachment ->
        if Attachment.html?(attachment) do
          ref = Cards.ref(board, card)
          {:ok, push_navigate(socket, to: ~p"/board/#{board.slug}?card=#{ref}&mockup=#{attachment.id}")}
        else
          raise Ecto.NoResultsError, queryable: Attachment
        end

      nil ->
        raise Ecto.NoResultsError, queryable: Attachment
    end
  end

  # Never reached: mount/3 always redirects or raises.
  @impl true
  def render(assigns), do: ~H""
end
