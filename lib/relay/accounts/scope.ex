defmodule Relay.Accounts.Scope do
  @moduledoc """
  The current-user scope handed to LiveViews and controllers as
  `current_scope` (Phoenix 1.8 convention; `<Layouts.app>` expects it).
  `nil` means "not signed in".
  """

  alias Relay.Accounts.User

  defstruct user: nil

  @doc "Builds a scope for a signed-in user; returns nil for nil."
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil
end
