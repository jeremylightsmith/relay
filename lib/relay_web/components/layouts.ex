defmodule RelayWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use RelayWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :wide, :boolean,
    default: false,
    doc: "when true, use the full-width content container (board pages)"

  attr :crumb, :boolean,
    default: false,
    doc: "render the 'Boards' breadcrumb button + separator before the title"

  slot :title, doc: "the bar's title node (editable board name, or a plain span)"
  slot :actions, doc: "the view's contextual right-side controls"
  slot :menu_items, doc: "view-specific entries at the top of the avatar dropdown"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header
      id="top-bar"
      class="flex items-center gap-3 border-b border-base-300 bg-base-100 px-4 sm:px-5"
      style="height:53px;"
    >
      <.link
        navigate={~p"/boards"}
        id="top-bar-logo"
        title="All boards"
        class="flex items-center gap-2"
      >
        <img src={~p"/images/logo_light_128.png"} width="23" alt="Relay" />
        <span class="text-[15px] font-semibold tracking-[-0.02em]">Relay</span>
      </.link>
      <div
        :if={@crumb or @title != []}
        style="width:1px;height:18px;background:oklch(0.90 0.006 255);flex:0 0 auto;"
      >
      </div>
      <div :if={@crumb} id="top-bar-crumb" class="flex flex-none items-center gap-[7px]">
        <.link
          navigate={~p"/boards"}
          id="top-bar-crumb-boards"
          class="flex items-center gap-1.5 rounded-[7px] px-[7px] py-1 text-[13px] font-semibold"
          style="color:oklch(0.50 0.02 255);"
        >
          <.icon name="hero-squares-2x2" class="size-3.5" /> Boards
        </.link>
        <span class="text-[13px]" style="color:oklch(0.78 0.02 255);">/</span>
      </div>
      <div id="top-bar-title" class="flex min-w-0 items-center text-[13px] font-medium">
        {render_slot(@title)}
      </div>
      <span class="flex-1"></span>
      {render_slot(@actions)}
      <div :if={@current_scope} id="top-bar-account" class="dropdown dropdown-end flex-none">
        <div
          tabindex="0"
          role="button"
          id="user-avatar"
          title={@current_scope.user.email}
          class={[
            "flex min-h-[44px] min-w-[44px] items-center justify-center",
            if(@current_scope.user.avatar_url, do: "avatar", else: "avatar avatar-placeholder")
          ]}
        >
          <div :if={@current_scope.user.avatar_url} class="w-7 rounded-full">
            <img
              src={@current_scope.user.avatar_url}
              alt={@current_scope.user.name || @current_scope.user.email}
              referrerpolicy="no-referrer"
            />
          </div>
          <div
            :if={!@current_scope.user.avatar_url}
            class="bg-primary text-primary-content w-7 rounded-full"
          >
            <span class="text-xs">{initials(@current_scope.user)}</span>
          </div>
        </div>
        <ul
          tabindex="0"
          id="account-menu"
          class="menu dropdown-content z-50 mt-2 w-60 rounded-box bg-base-100 p-2 shadow"
        >
          {render_slot(@menu_items)}
          <li class="menu-title px-2 text-[10px] uppercase tracking-wider">Theme</li>
          <li>
            <div class="pointer-events-auto px-1 py-1 hover:bg-transparent">
              <.theme_toggle />
            </div>
          </li>
          <li>
            <.link href={~p"/logout"} method="delete" id="sign-out">
              <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Sign out
            </.link>
          </li>
        </ul>
      </div>
    </header>

    <main class={[
      if(@wide, do: "px-0 py-0", else: "px-4 py-20 sm:px-6 lg:px-8")
    ]}>
      <div class={[if(@wide, do: "max-w-none", else: "mx-auto max-w-2xl space-y-4")]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  # Initials for the avatar fallback, from the user's name (or email
  # when the name is missing). Works on any user-shaped map or the
  # Schemas.User struct.
  defp initials(user) do
    (user.name || user.email)
    |> String.split(~r/[\s@._-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
