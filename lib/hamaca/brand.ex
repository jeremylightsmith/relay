defmodule Hamaca.Brand do
  @moduledoc """
  The one source for the user-facing product and agent names (RE477). Every code-level use of
  the name a person reads — the agent's display name, the API's agent `name`, the web chrome —
  calls this module instead of re-typing the literal.
  """

  use Boundary, deps: []

  @doc "The product name a person reads."
  @spec name() :: String.t()
  def name, do: "Hamaca"

  @doc "The agent's display name."
  @spec agent_name() :: String.t()
  def agent_name, do: "Hamaca AI"
end
