defmodule RelayWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use RelayWeb, :controller
      use RelayWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  use Boundary, deps: [Relay, Schemas], exports: [Endpoint, Telemetry, ApiLog]

  def static_paths, do: ~w(assets fonts images sounds favicon.ico robots.txt)

  @doc """
  RE322 — where an uploaded attachment is served (`AttachmentController.show`). `CardJSON`
  builds the `url` and `markdown` that `relay attach` hands back with it, and the drawer's
  screenshots strip recognises those urls with `attachment_path?/1`. The one definition lives
  domain-side on `Schemas.Attachment.path/1` (RE370 — `Relay.Cards` validates mockup urls and
  may not call the web layer); `RelayWeb.AttachmentPathTest` pins it to the router.
  """
  defdelegate attachment_path(id), to: Schemas.Attachment, as: :path

  @doc """
  Whether `path` is a path `attachment_path/1` builds: the prefix plus a non-empty, single-segment
  id. A bare `/attachments`, a nested path, or a non-string is not.
  """
  defdelegate attachment_path?(path), to: Schemas.Attachment, as: :path?

  @doc """
  RE428 — the absolute URL an attachment is served from (`attachment_path/1` on this endpoint),
  e.g. `"http://localhost:4002/attachments/<id>"`. It is what the link a reject note or an answer
  carries points at, so the agent reading the text can resolve it.
  """
  @spec attachment_url(Ecto.UUID.t()) :: String.t()
  def attachment_url(id), do: RelayWeb.Endpoint.url() <> attachment_path(id)

  @doc """
  The markdown image link for an attachment: `"![<filename>](<url>)"`. `filename` is user data, so
  `\\`, `[`, `]` and `)` are backslash-escaped and the alt text always round-trips to the literal
  name. The one builder: `RelayWeb.Api.CardJSON.attachment/1` and the reject/answer image links
  (RE428) both call it.
  """
  @spec image_markdown(String.t(), String.t()) :: String.t()
  def image_markdown(filename, url), do: "![#{escape_markdown_text(filename)}](#{url})"

  defp escape_markdown_text(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
    |> String.replace(")", "\\)")
  end

  @doc """
  Legacy RE370 link; redirects to the BoardLive viewer. `MockupViewerLive` serves it as a
  membership-scoped redirect to the card's drawer URL plus `mockup=<id>` (RE380), so old links
  keep working; nothing in Relay's UI links here any more. `RelayWeb.AttachmentPathTest` pins it
  to the router.
  """
  def attachment_view_path(id), do: attachment_path(id) <> "/view"

  @doc """
  RE370 — the sandbox token list an HTML mockup runs under: scripts on, and nothing else — no
  `allow-same-origin` (opaque origin: no cookies, no parent access), no `allow-top-navigation`,
  `allow-popups` or `allow-forms`. The ONE definition: `AttachmentController.html_csp/0` puts it
  in the CSP `sandbox` directive and every mockup `<iframe sandbox=…>` (the drawer's
  `CoreComponents.mockup_preview/1` tiles and the viewer's `CoreComponents.card_mockup_viewer/1`)
  uses it as the attribute value.
  """
  def mockup_sandbox, do: "allow-scripts"

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Phoenix.Controller
      import Phoenix.LiveView.Router

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]
      use Gettext, backend: RelayWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: RelayWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import RelayWeb.CoreComponents

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias RelayWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: RelayWeb.Endpoint,
        router: RelayWeb.Router,
        statics: RelayWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
