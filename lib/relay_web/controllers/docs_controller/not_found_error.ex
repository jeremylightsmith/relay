defmodule RelayWeb.DocsController.NotFoundError do
  @moduledoc """
  Raised when a requested docs slug isn't in the compile-time page registry.

  Unlike `Phoenix.Router.NoRouteError` (which `Phoenix.Endpoint.RenderErrors` deliberately does
  not re-raise, so `assert_error_sent/2` can't observe it), this exception propagates normally
  while still rendering as a 404 via the `Plug.Exception` fallback (`:plug_status`).
  """
  defexception plug_status: 404, message: "docs page not found"
end
