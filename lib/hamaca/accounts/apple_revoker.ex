defmodule Hamaca.Accounts.AppleRevoker do
  @moduledoc """
  Revokes a person's Sign in with Apple grant at account deletion (RE509, App Store Guideline
  5.1.1(v)). `revoke/2` takes a fresh authorization code from the app and the Apple `sub` the
  account was created with (`Schemas.User.provider_uid`); it returns `:ok` once Apple has
  revoked the token, `{:error, :apple_mismatch}` when the code belongs to another Apple
  account, and `{:error, :apple_revoke_failed}` for anything else.

  `impl/0` is the seam: `:apple_revoker` through `Hamaca.Config`, `AppleRevoker.Apple` (Apple's
  REST API) by default.

  Belongs to the `Hamaca.Accounts` boundary (no own `use Boundary`); not exported.
  """

  @doc "Exchanges `authorization_code` with Apple, checks its `sub` is `expected_sub`, and revokes the token."
  @callback revoke(authorization_code :: String.t(), expected_sub :: String.t()) ::
              :ok | {:error, :apple_mismatch | :apple_revoke_failed}

  @doc "The configured implementation: `:apple_revoker`, `AppleRevoker.Apple` by default."
  @spec impl() :: module()
  def impl, do: Hamaca.Config.get(:apple_revoker, Hamaca.Accounts.AppleRevoker.Apple)
end
