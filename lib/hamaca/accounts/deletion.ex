defmodule Hamaca.Accounts.Deletion do
  @moduledoc """
  Account deletion (RE509): what deleting a person's account would do (`preview/1`), and doing
  it (`delete_account/2`). Exposed as `Hamaca.Accounts.deletion_preview/1`,
  `Hamaca.Accounts.delete_account/2` and `Hamaca.Accounts.deletion_errors/0`.

  The person's **owned boards** split in two. A **shared** board has another resolved, live
  member and goes to the member the person picks (`transfers`, slug → user id). A **solo** board
  has nobody else (pending invites don't count) and is deleted. On every board that survives,
  the person's runner keys (`Schemas.SetupMachine.api_key_id`) are revoked and their membership
  removed, with `{:member_removed, user_id}` broadcast so open sessions eject. Their card
  ownerships, user API tokens, device tokens, usage visits and billing account go too.

  The user row is **tombstoned** (`Schemas.User.deletion_changeset/1`), never deleted:
  comments, activities and votes cascade on a user delete, and they stay, shown as
  `Schemas.User.deleted_name/0`.

  Nothing is written until the transfers check out against a fresh preview and an Apple
  account's Apple grant is revoked (`Hamaca.Accounts.AppleRevoker`); the transaction
  re-checks them and is all-or-nothing. The Stripe customer is deleted after commit, best
  effort — a failure is logged and never undoes the deletion.

  Belongs to the `Hamaca.Accounts` boundary (no own `use Boundary`).
  """

  import Ecto.Query

  alias Hamaca.Accounts.AppleRevoker
  alias Hamaca.ApiKeys
  alias Hamaca.Billing
  alias Hamaca.Billing.Standing
  alias Hamaca.Events
  alias Hamaca.Repo
  alias Schemas.ApiKey
  alias Schemas.Board
  alias Schemas.CardOwner
  alias Schemas.DeviceToken
  alias Schemas.Membership
  alias Schemas.SetupMachine
  alias Schemas.UsageVisit
  alias Schemas.User
  alias Schemas.UserApiToken

  require Logger

  @errors [:confirm_required, :invalid_transfers, :apple_reauth_required, :apple_mismatch, :apple_revoke_failed]
  @unnamed_runner "unnamed runner"
  @personal_rows [CardOwner, UserApiToken, DeviceToken, UsageVisit]

  @typedoc "Why a deletion was refused — the closed set `errors/0`."
  @type error ::
          :confirm_required | :invalid_transfers | :apple_reauth_required | :apple_mismatch | :apple_revoke_failed

  @typedoc "A member a shared board can go to."
  @type candidate :: %{
          user_id: pos_integer(),
          name: String.t() | nil,
          avatar_url: String.t() | nil,
          member_since: Date.t()
        }

  @typedoc "What deleting the account would do."
  @type preview :: %{
          shared_boards: [
            %{slug: String.t(), name: String.t(), member_count: pos_integer(), candidates: [candidate()]}
          ],
          solo_boards: [%{slug: String.t(), name: String.t()}],
          plan_ends: boolean(),
          runners: [String.t()],
          apple_reauth_required: boolean()
        }

  @doc """
  The closed set of deletion error atoms, in order. `:confirm_required` is checked by the web
  layer (the typed `DELETE`), but lives here so this is the ONE list.
  """
  @spec errors() :: [error()]
  def errors, do: @errors

  @doc """
  What deleting `user`'s account would do:

    * `shared_boards` — owned boards (archived included) with another resolved, live member.
      `member_count` counts every resolved membership, the user's included; `candidates` are the
      other live members, longest-serving first (membership `inserted_at`, then `id`) — the first
      is the default new owner.
    * `solo_boards` — the other owned boards, which will be deleted.
    * `plan_ends` — billing is on and the user is on a paying plan (`Billing.paying_plans/0`).
    * `runners` — the names of the user's live-keyed machines on surviving boards, which stop.
    * `apple_reauth_required` — an Apple account must re-authenticate with Apple.

  Both board lists are ordered by name, then id.
  """
  @spec preview(User.t()) :: preview()
  def preview(%User{} = user) do
    {shared, solo} = owned_boards(user)

    %{
      shared_boards: Enum.map(shared, &shared_board/1),
      solo_boards: Enum.map(solo, &%{slug: &1.slug, name: &1.name}),
      plan_ends: plan_ends?(user),
      runners: runners(user, Enum.map(solo, & &1.id)),
      apple_reauth_required: apple_reauth_required?(user)
    }
  end

  @doc """
  Deletes `user`'s account. `opts[:transfers]` maps the slug of **every** shared board (and
  nothing else) to the user id of one of its candidates; anything else is
  `{:error, :invalid_transfers}` and nothing is written. Returns `:ok` once committed.

  An Apple account (`apple_reauth_required` in the preview) then needs a fresh
  `opts[:apple_authorization_code]`: none, or a blank one, is `{:error, :apple_reauth_required}`;
  otherwise its Apple grant is revoked (`Hamaca.Accounts.AppleRevoker`) **before** anything is
  written, and `{:error, :apple_mismatch}` / `{:error, :apple_revoke_failed}` leave the account
  untouched. `allow_without_apple_revoke: true` skips the revoke. The transfers are checked
  first, so `:invalid_transfers` wins and Apple is never called for it.
  """
  @spec delete_account(User.t(), keyword()) :: :ok | {:error, error()}
  def delete_account(%User{} = user, opts \\ []) do
    transfers = Keyword.get(opts, :transfers, %{})

    with :ok <- validate_transfers(owned_boards(user), transfers),
         :ok <- revoke_apple(user, opts),
         {:ok, customer_id} <- Repo.transaction(fn -> delete_in_transaction(user, transfers) end) do
      delete_stripe_customer(user, customer_id)
    end
  end

  # Order matters: transfers, then solo boards, keys, personal rows, billing, and the tombstone last.
  defp delete_in_transaction(user, transfers) do
    {shared, solo} = boards = owned_boards(user)
    # The boards may have changed since the caller's preview — re-check against the fresh set.
    if validate_transfers(boards, transfers) != :ok, do: Repo.rollback(:invalid_transfers)

    Enum.each(shared, fn %{board: board} -> transfer!(board, Map.fetch!(transfers, board.slug)) end)
    Enum.each(solo, &Repo.delete!/1)
    revoke_runner_keys(user)
    remove_memberships(user)
    Enum.each(@personal_rows, fn schema -> Repo.delete_all(from r in schema, where: r.user_id == ^user.id) end)
    {:ok, customer_id} = Billing.remove_account(user)
    user |> User.deletion_changeset() |> Repo.update!()

    customer_id
  end

  # An Apple account revokes its Apple grant before anything is written, with a fresh code
  # (`opts[:apple_authorization_code]`); `allow_without_apple_revoke: true` skips it.
  defp revoke_apple(user, opts) do
    code = opts[:apple_authorization_code]

    cond do
      not apple_reauth_required?(user) or opts[:allow_without_apple_revoke] -> :ok
      not is_binary(code) or String.trim(code) == "" -> {:error, :apple_reauth_required}
      true -> AppleRevoker.impl().revoke(code, user.provider_uid)
    end
  end

  defp apple_reauth_required?(user), do: user.provider == "apple"

  defp validate_transfers({shared, _solo}, transfers) when is_map(transfers) do
    allowed = Map.new(shared, fn %{board: board, candidates: candidates} -> {board.slug, candidates} end)

    valid? =
      map_size(transfers) == map_size(allowed) and
        Enum.all?(transfers, fn {slug, user_id} ->
          Enum.any?(Map.get(allowed, slug, []), &(&1.user_id == user_id))
        end)

    if valid?, do: :ok, else: {:error, :invalid_transfers}
  end

  defp validate_transfers(_boards, _transfers), do: {:error, :invalid_transfers}

  defp transfer!(board, new_owner_id) do
    board = board |> Ecto.Changeset.change(owner_id: new_owner_id) |> Repo.update!()
    Events.broadcast(board.id, {:board_updated, board})
  end

  defp revoke_runner_keys(user) do
    from(k in ApiKey,
      join: m in SetupMachine,
      on: m.api_key_id == k.id,
      where: m.user_id == ^user.id,
      distinct: true
    )
    |> Repo.all()
    |> Enum.each(fn key -> {:ok, _revoked} = ApiKeys.revoke(key) end)
  end

  # Like `Hamaca.Members.remove/1`, in bulk: open sessions on each surviving board eject.
  defp remove_memberships(user) do
    {_count, board_ids} =
      Repo.delete_all(from m in Membership, where: m.user_id == ^user.id, select: m.board_id)

    board_ids |> Enum.uniq() |> Enum.each(&Events.broadcast(&1, {:member_removed, user.id}))
  end

  defp delete_stripe_customer(user, customer_id) do
    case Billing.delete_customer(customer_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "account deletion: Stripe customer #{customer_id} of deleted user #{user.id} was not deleted: #{inspect(reason)}"
        )

        :ok
    end
  end

  # {shared, solo}: shared as %{board, member_count, candidates}, solo as boards; both by name, id.
  defp owned_boards(user) do
    boards = Repo.all(from b in Board, where: b.owner_id == ^user.id, order_by: [asc: b.name, asc: b.id])

    members =
      from(m in Membership,
        join: u in assoc(m, :user),
        where: m.board_id in ^Enum.map(boards, & &1.id),
        order_by: [asc: m.inserted_at, asc: m.id],
        select: {m, u}
      )
      |> Repo.all()
      |> Enum.group_by(fn {m, _u} -> m.board_id end)

    boards
    |> Enum.map(fn board ->
      board_members = Map.get(members, board.id, [])

      candidates =
        for {m, u} <- board_members, u.id != user.id, is_nil(u.deleted_at) do
          %{user_id: u.id, name: u.name, avatar_url: u.avatar_url, member_since: DateTime.to_date(m.inserted_at)}
        end

      %{board: board, member_count: length(board_members), candidates: candidates}
    end)
    |> Enum.split_with(&(&1.candidates != []))
    |> then(fn {shared, solo} -> {shared, Enum.map(solo, & &1.board)} end)
  end

  defp shared_board(%{board: board, member_count: member_count, candidates: candidates}),
    do: %{slug: board.slug, name: board.name, member_count: member_count, candidates: candidates}

  defp plan_ends?(user) do
    Billing.enabled?() and Standing.kind(Billing.standing(user, Date.utc_today())) in Billing.paying_plans()
  end

  defp runners(user, solo_board_ids) do
    from(m in SetupMachine,
      where: m.user_id == ^user.id and not is_nil(m.api_key_id) and m.board_id not in ^solo_board_ids,
      order_by: [asc: m.id],
      select: {m.runner_name, m.host}
    )
    |> Repo.all()
    |> Enum.map(fn {runner_name, host} -> runner_name || host || @unnamed_runner end)
    |> Enum.uniq()
  end
end
