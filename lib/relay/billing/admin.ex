defmodule Relay.Billing.Admin do
  @moduledoc """
  The superadmin's billing writes (RE463), reached only through `Relay.Billing`'s delegates:
  comp / uncomp, hold / lift hold, extend `paid_through` by N days, and retry the charge now.

  Each write follows `Relay.Billing.redeem_code/3`'s shape: `ensure_account/1` first, then one
  transaction that locks the account `FOR UPDATE`, checks it, changes it and writes **exactly
  one** `Schemas.BillingAdminEntry` through `record!/3` — the one history writer — then
  `{:billing_changed, user_id}` after the commit. A refusal (one of
  `Relay.Billing.admin_refusals/0`) writes and broadcasts nothing; an input refusal (a blank
  reason, days out of range) is answered before any account is touched.

  The retry is the exception to the one transaction: `Relay.Billing.Charging` owns its own
  open → send → settle transactions, so its entry is recorded after the charge returns.
  """

  import Ecto.Query

  alias Relay.Billing
  alias Relay.Billing.Charging
  alias Relay.Billing.Standing
  alias Relay.Repo
  alias Schemas.BillingAccount
  alias Schemas.BillingAdminEntry
  alias Schemas.User

  @extend_max_days 365

  @doc "The most days one extend may add."
  @spec extend_max_days() :: 365
  def extend_max_days, do: @extend_max_days

  @doc "Comps the account (`comped: true`); refused when it already is."
  @spec comp(pos_integer(), User.t(), Date.t()) :: {:ok, BillingAccount.t()} | {:error, :already_comped}
  def comp(user_id, %User{} = actor, %Date{} = _today) do
    write(user_id, actor, fn
      %BillingAccount{comped: true} -> {:error, :already_comped}
      _account -> {:ok, [comped: true], %{action: :comp}}
    end)
  end

  @doc "Un-comps the account; its standing is then derived as usual. Refused when not comped."
  @spec uncomp(pos_integer(), User.t(), Date.t()) :: {:ok, BillingAccount.t()} | {:error, :not_comped}
  def uncomp(user_id, %User{} = actor, %Date{} = _today) do
    write(user_id, actor, fn
      %BillingAccount{comped: true} -> {:ok, [comped: false], %{action: :uncomp}}
      _account -> {:error, :not_comped}
    end)
  end

  @doc "Holds the account from `today` for the trimmed `reason` (required). Refused when already held."
  @spec hold(pos_integer(), User.t(), String.t() | nil, Date.t()) ::
          {:ok, BillingAccount.t()} | {:error, :reason_required | :already_held}
  def hold(user_id, %User{} = actor, reason, %Date{} = today) do
    with {:ok, reason} <- required_reason(reason) do
      write(user_id, actor, fn
        %BillingAccount{held_on: %Date{}} -> {:error, :already_held}
        _account -> {:ok, [held_on: today, hold_reason: reason], %{action: :hold, reason: reason}}
      end)
    end
  end

  @doc "Lifts the account's hold. Refused when it is not held."
  @spec lift_hold(pos_integer(), User.t(), Date.t()) :: {:ok, BillingAccount.t()} | {:error, :not_held}
  def lift_hold(user_id, %User{} = actor, %Date{} = _today) do
    write(user_id, actor, fn
      %BillingAccount{held_on: %Date{}} -> {:ok, [held_on: nil, hold_reason: nil], %{action: :lift_hold}}
      _account -> {:error, :not_held}
    end)
  end

  @doc """
  Moves `paid_through` on by `days` (1..`extend_max_days/0`) for the trimmed `reason`
  (required). The billing day is untouched and nothing is charged. Checked in order: the days,
  the reason, then a `paid_through` to extend.
  """
  @spec extend(pos_integer(), User.t(), integer(), String.t() | nil, Date.t()) ::
          {:ok, BillingAccount.t()} | {:error, :invalid_days | :reason_required | :no_paid_through}
  def extend(user_id, %User{} = actor, days, reason, %Date{} = _today) do
    with :ok <- valid_days(days),
         {:ok, reason} <- required_reason(reason) do
      write(user_id, actor, fn
        %BillingAccount{paid_through: nil} ->
          {:error, :no_paid_through}

        %BillingAccount{paid_through: before} ->
          later = Date.add(before, days)

          {:ok, [paid_through: later],
           %{action: :extend, days: days, reason: reason, paid_through_before: before, paid_through_after: later}}
      end)
    end
  end

  @doc """
  Charges the account now through `Charging.admin_retry/2`, when `Relay.Billing.admin_retryable?/2`
  holds on a fresh read; records one `:retry_charge` entry with `paid_through` either side.
  """
  @spec retry_charge(pos_integer(), User.t(), Date.t()) ::
          {:ok, :paid | :declined | :unknown | :none} | {:error, :not_retryable}
  def retry_charge(user_id, %User{} = actor, %Date{} = today) do
    account = Billing.get_account(user_id)

    if Billing.admin_retryable?(account, Standing.of(account, Charging.facts(account), today)) do
      outcome = Charging.admin_retry(account.id, today)
      %BillingAccount{paid_through: after_retry} = Repo.get!(BillingAccount, account.id)

      record!(account, actor, %{
        action: :retry_charge,
        paid_through_before: account.paid_through,
        paid_through_after: after_retry
      })

      :ok = Billing.broadcast_changed(user_id)
      {:ok, outcome}
    else
      {:error, :not_retryable}
    end
  end

  # The shape of every admin write but the retry. `decide` sees the locked account and answers
  # `{:ok, account_changes, entry_fields}` or `{:error, refusal}`.
  defp write(user_id, actor, decide) do
    {:ok, %BillingAccount{id: account_id}} = Billing.ensure_account(user_id)

    written =
      Repo.transact(fn ->
        account = Repo.one!(from a in BillingAccount, where: a.id == ^account_id, lock: "FOR UPDATE")

        with {:ok, changes, entry} <- decide.(account) do
          updated = account |> Ecto.Changeset.change(changes) |> Repo.update!()
          record!(updated, actor, entry)
          {:ok, updated}
        end
      end)

    with {:ok, account} <- written do
      :ok = Billing.broadcast_changed(account.user_id)
      {:ok, account}
    end
  end

  # THE one admin-history writer.
  defp record!(%BillingAccount{id: account_id}, %User{id: actor_id}, fields) do
    BillingAdminEntry
    |> struct(fields)
    |> Map.merge(%{billing_account_id: account_id, actor_id: actor_id})
    |> Repo.insert!()
  end

  defp required_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :reason_required}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_reason(_reason), do: {:error, :reason_required}

  defp valid_days(days) when is_integer(days) and days in 1..@extend_max_days//1, do: :ok
  defp valid_days(_days), do: {:error, :invalid_days}
end
