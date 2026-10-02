defmodule RelayWeb.MockupViewerLive do
  @moduledoc """
  RE370 — the full-size viewer for an HTML mockup at `/attachments/:id/view`
  (`RelayWeb.attachment_view_path/1`). A persistent banner — "Mockup · <ref> <title>", linking
  back to the card — sits over a full-viewport `<iframe sandbox="allow-scripts">`
  (`RelayWeb.mockup_sandbox/0`) of the raw attachment, which `AttachmentController` serves under
  the sandbox CSP.

  This page exists so Relay's UI never presents a mockup as a bare top-level page (the residual
  same-domain-phishing risk in `AttachmentController`'s threat model): it is always framed under
  Relay chrome that names where it came from.

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

          {:ok,
           assign(socket,
             attachment: attachment,
             board: board,
             card: card,
             ref: ref,
             page_title: "Mockup · #{ref}"
           )}
        else
          raise Ecto.NoResultsError, queryable: Attachment
        end

      nil ->
        raise Ecto.NoResultsError, queryable: Attachment
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide embed={@embed}>
      <:title>
        <span id="mockup-viewer-title" class="truncate">Mockup</span>
      </:title>
      <div id="mockup-viewer" class="flex h-[calc(100vh-53px)] flex-col">
        <div
          id="mockup-viewer-banner"
          role="note"
          class="flex min-w-0 items-center gap-2 border-b border-base-300 bg-base-200 px-4 py-2 text-sm"
        >
          <.icon name="hero-eye" class="size-4 shrink-0 text-base-content/60" />
          <span class="shrink-0 font-semibold">Mockup</span>
          <span class="shrink-0 text-base-content/40">·</span>
          <.link
            id="mockup-viewer-card-link"
            navigate={~p"/board/#{@board.slug}?card=#{@ref}"}
            class="min-w-0 truncate hover:underline"
          >
            <span class="font-mono text-xs text-base-content/65">{@ref}</span>
            <span class="font-medium">{@card.title}</span>
          </.link>
          <span class="ml-auto shrink-0 truncate text-xs text-base-content/60">
            {@attachment.filename}
          </span>
        </div>
        <iframe
          id="mockup-viewer-frame"
          src={RelayWeb.attachment_path(@attachment.id)}
          sandbox={RelayWeb.mockup_sandbox()}
          title={"Mockup for #{@ref}"}
          class="block min-h-0 w-full flex-1 border-0 bg-base-100"
        >
        </iframe>
      </div>
    </Layouts.app>
    """
  end
end
