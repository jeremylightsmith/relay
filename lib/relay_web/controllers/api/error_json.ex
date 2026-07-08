defmodule RelayWeb.Api.ErrorJSON do
  @moduledoc "Renders the API's consistent error shape."

  def error(%{code: code, message: message}) do
    %{error: %{code: code, message: message}}
  end
end
