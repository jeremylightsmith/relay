defmodule RelayWeb.PageController do
  @moduledoc """
  Public sign-in page. Signed-in users are sent straight to the app home.
  """

  use RelayWeb, :controller

  def home(conn, _params) do
    if conn.assigns.current_scope do
      redirect(conn, to: ~p"/home")
    else
      render(conn, :home)
    end
  end
end
