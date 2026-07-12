defmodule Relay.Members do
  @moduledoc """
  The Members context (RLY-32): who has access to a board. Everyone is a
  member; there are no roles. A membership with `user_id == nil` is an
  *invited* pre-authorization keyed on an email; it resolves when that email
  signs in (`resolve_invites_for_user/1`) or immediately at invite time when
  the email already belongs to a registered user.

  Relay AI is **not** a membership — it is derived from the board's API key
  and rendered as the fixed AGENT presence elsewhere.

  Board *access* (which boards a user can load) lives in `Relay.Boards`, which
  now joins `board_members`; this context owns the membership rows themselves.
  """

  use Boundary, deps: [Relay.Events, Relay.Repo, Schemas]

  import Ecto.Query

  alias Relay.Events
  alias Relay.Repo
  alias Schemas.Board
  alias Schemas.Membership
  alias Schemas.User

  @doc """
  The board's memberships, `:user` preloaded (nil for invited rows), oldest
  first. Includes invited (user-less) rows.
  """
  def list_members(%Board{id: board_id}) do
    Repo.all(
      from m in Membership,
        where: m.board_id == ^board_id,
        order_by: [asc: m.inserted_at, asc: m.id],
        preload: [:user]
    )
  end

  @doc "True when `user` holds a resolved membership on `board`."
  def member?(%Board{id: board_id}, %User{id: user_id}) do
    Repo.exists?(from m in Membership, where: m.board_id == ^board_id and m.user_id == ^user_id)
  end

  @doc """
  Invites `email` to `board`. Normalizes the address; if a registered user
  already owns that email the membership is created **resolved** (`user_id`
  set) immediately, otherwise **invited** (`user_id: nil`). No email is sent —
  the invite is a pre-authorization. Returns `{:ok, membership}` (`:user`
  preloaded), `{:error, :already_member}` on the `(board_id, email)` conflict,
  or `{:error, changeset}` for a blank/invalid address.
  """
  def invite(%Board{} = board, email) do
    normalized = normalize(email)
    user = normalized && Repo.get_by(User, email: normalized)

    %Membership{board_id: board.id, user_id: user && user.id}
    |> Membership.changeset(%{email: normalized})
    |> Repo.insert()
    |> case do
      {:ok, membership} -> {:ok, Repo.preload(membership, :user)}
      {:error, changeset} -> translate_insert_error(changeset)
    end
  end

  @doc """
  Removes `membership`: deletes the row and broadcasts
  `{:member_removed, user_id}` on the board's `Relay.Events` topic so open
  sessions can eject. Removing an invited (user-less) row broadcasts with a
  `nil` id (harmless — no session matches). Returns `{:ok, membership}`.
  """
  def remove(%Membership{} = membership) do
    {:ok, deleted} = Repo.delete(membership)
    Events.broadcast(membership.board_id, {:member_removed, membership.user_id})
    {:ok, deleted}
  end

  @doc """
  Resolves any invited membership whose `email` matches `user.email` by
  setting its `user_id`. Called from the login chokepoint; idempotent (a
  user with no pending invites is a no-op). Returns `:ok`.
  """
  def resolve_invites_for_user(%User{} = user) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.update_all(
      from(m in Membership, where: m.email == ^user.email and is_nil(m.user_id)),
      set: [user_id: user.id, updated_at: now]
    )

    :ok
  end

  defp translate_insert_error(changeset) do
    if Enum.any?(changeset.errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :unique end) do
      {:error, :already_member}
    else
      {:error, changeset}
    end
  end

  defp normalize(nil), do: nil

  defp normalize(email) when is_binary(email) do
    case email |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end
end
