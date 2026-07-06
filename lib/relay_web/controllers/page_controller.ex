defmodule RelayWeb.PageController do
  use RelayWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
