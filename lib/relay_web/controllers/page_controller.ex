defmodule RelayWeb.PageController do
  @moduledoc """
  Public landing page. Signed-in users are sent straight to the board.
  """

  use RelayWeb, :controller

  def home(conn, _params) do
    if conn.assigns.current_scope do
      redirect(conn, to: ~p"/board")
    else
      render(conn, :home)
    end
  end

  def privacy(conn, _params), do: render(conn, :privacy, page_title: "Privacy Policy")

  def terms(conn, _params), do: render(conn, :terms, page_title: "Terms of Service")
end
