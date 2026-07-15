defmodule Relay.Push do
  @moduledoc """
  Push notifications (RLY-81, brief §06): the reason Relay is on the phone.

  Owns registered devices (`Schemas.DeviceToken`), the recipient fan-out, the
  APNs payload, the app-icon badge count, and the delivery adapter seam
  (`Relay.Push.Delivery`).

  **Depends on `Relay.Members`/`Relay.Repo`, never on `Relay.Cards`** — `Cards`
  calls `Push` from `set_status/3`, so a back-dependency would be a boundary
  cycle. That is also why the card ref is formatted here rather than reusing
  `Cards.ref/2`.
  """

  use Boundary, deps: [Relay.Members, Relay.Repo, Schemas]

  import Ecto.Query

  alias Relay.Repo
  alias Schemas.Card
  alias Schemas.DeviceToken
  alias Schemas.Membership
  alias Schemas.User

  @doc """
  Registers `token` as a push device for `user`, upserting on the token: a
  device that re-registers (including after an account switch) re-points to
  `user` and re-stamps `last_registered_at` rather than duplicating.
  """
  def register_device(user, token, platform \\ :ios)

  def register_device(%User{} = user, token, platform) when is_binary(token) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    %DeviceToken{user_id: user.id}
    |> DeviceToken.changeset(%{token: token, platform: platform, last_registered_at: now})
    |> Repo.insert(
      conflict_target: :token,
      on_conflict: [set: [user_id: user.id, platform: platform, last_registered_at: now, updated_at: now]]
    )
  end

  @doc """
  Removes `user`'s registration of `token` (sign-out cleanup). Idempotent, and
  scoped to `user` so one account can never unregister another's device.
  """
  def unregister_device(%User{id: user_id}, token) when is_binary(token) do
    Repo.delete_all(from d in DeviceToken, where: d.user_id == ^user_id and d.token == ^token)
    :ok
  end

  @doc """
  Deletes `token`'s registration regardless of owner. For delivery adapters
  pruning a device Apple reported as gone (410 Unregistered / 400
  BadDeviceToken), where there is no user in hand. Idempotent.
  """
  def delete_device_token(token) when is_binary(token) do
    Repo.delete_all(from d in DeviceToken, where: d.token == ^token)
    :ok
  end

  @doc """
  How many cards need `user`: unarchived cards in `:needs_input` or `:in_review`
  on any board `user` is a resolved member of, across boards. Stamped onto every
  push as `aps.badge`.

  **F4 overlap (ADR 0005):** F4 (RLY-80) computes the same two-status set for the
  inbox feed and the two must agree. F5 landed first, so this query owns the
  definition; F4 reuses it rather than adding a second one.
  """
  def needs_you_count(%User{id: user_id}) do
    Repo.aggregate(
      from(c in Card,
        join: m in Membership,
        on: m.board_id == c.board_id,
        where: m.user_id == ^user_id,
        where: c.status in [:needs_input, :in_review],
        where: is_nil(c.archived_at)
      ),
      :count
    )
  end

  @doc "The configured delivery adapter (see `Relay.Push.Delivery`)."
  def adapter do
    :relay
    |> Application.get_env(Relay.Push, [])
    |> Keyword.get(:adapter, Relay.Push.Delivery.Log)
  end
end
