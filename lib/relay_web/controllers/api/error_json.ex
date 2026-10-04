defmodule RelayWeb.Api.ErrorJSON do
  @moduledoc "Renders the API's consistent error shape."

  @doc """
  `{"error": {"code", "message"}}`. Optional `details` keys merge into the `error` object
  (RE384 — e.g. a stage refusal's `live`/`archived` counts or `flows`); without `details` the
  body is unchanged.
  """
  @spec error(%{required(:code) => String.t(), required(:message) => String.t(), optional(:details) => map()}) :: map()
  def error(%{code: code, message: message} = assigns) do
    details = Map.get(assigns, :details, %{})
    %{error: Map.merge(details, %{code: code, message: message})}
  end
end
