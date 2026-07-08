defmodule RelayWeb.Api.CardController do
  use RelayWeb, :controller

  action_fallback RelayWeb.Api.FallbackController
end
