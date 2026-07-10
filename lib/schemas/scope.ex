defmodule Schemas.Scope do
  @moduledoc """
  The current-user scope handed to LiveViews and controllers as
  `current_scope` (Phoenix 1.8 convention; `<Layouts.app>` expects it).
  `nil` means "not signed in".
  """

  alias Schemas.User

  defstruct user: nil

  @doc "Builds a scope for a signed-in user; returns nil for nil."
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil

  # For now a superadmin is a fixed allowlist of emails; later this becomes a
  # real role. Gates everything under /admin (see RelayWeb.Auth).
  @superadmin_emails ["jeremy.lightsmith@gmail.com"]

  @doc "True when the scope belongs to a superadmin."
  def superadmin?(%__MODULE__{user: %User{email: email}}), do: email in @superadmin_emails
  def superadmin?(_), do: false
end
