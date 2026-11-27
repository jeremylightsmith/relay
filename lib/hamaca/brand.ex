defmodule Hamaca.Brand do
  @moduledoc """
  The one source for the user-facing product and agent names (RE477) and the support address
  (RE510). Every code-level use of
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

  @doc """
  The one support address a person can write to (RE510) — published on `/privacy`, `/terms` and
  `/support`.
  """
  @spec support_email() :: String.t()
  def support_email, do: "jeremy.lightsmith@gmail.com"
end
