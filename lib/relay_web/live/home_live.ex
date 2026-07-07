defmodule RelayWeb.HomeLive do
  @moduledoc """
  Post-login stub home ("You're signed in as {name}"). Replaced by the
  board in MMF 02.
  """

  use RelayWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="home-stub" class="text-center space-y-2 py-12">
        <h1 class="text-xl font-semibold">
          You're signed in as {@current_scope.user.name || @current_scope.user.email}
        </h1>
        <p class="text-base-content/70">The board arrives in the next release.</p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end
end
