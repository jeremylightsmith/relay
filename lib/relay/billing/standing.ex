defmodule Relay.Billing.Standing do
  @moduledoc """
  The standing a billing account is in today (RE460, ADR 0012; Free since RE469): pure, derived
  from the account's stored facts, never stored itself. A port of Throughway's
  `Plans.Standing.of/3` with one price, `paid_through` standing in for the plan state and a
  `grace_days/0` grace.

  The first matching rule wins:

    1. no account → `:free`;
    2. `held_on` set → `{:paused, :hold}` (the only pause);
    3. `comped` → `:comped`;
    4. `cancelled_on` set → `{:cancelled, access_until}` through `access_until`, then `:free`;
    5. never paid (`paid_through` nil) → `:free`, card or no card;
    6. paid: `:active` through `paid_through`, `{:past_due, paid_through + grace_days()}` during
       the grace, then `:free`.

  Free is limited (one editable board, `Relay.Billing.free_board_limit/0`); every standing
  `unlimited?/1` answers true for has no board limit. `facts` is still taken (every caller
  passes `Relay.Billing.Charging.facts/1,2`), but no rule reads it any more.
  """

  @kinds [:free, :active, :past_due, :cancelled, :comped, :paused]
  @pause_reasons [:hold]
  @grace_days 1

  @type pause_reason :: :hold
  @type t ::
          :free
          | :active
          | :comped
          | {:past_due, until :: Date.t()}
          | {:cancelled, access_until :: Date.t()}
          | {:paused, pause_reason()}
  @typedoc """
  Facts about a never-paid account (both false once it has paid): `first_charge_declined?` — it
  has ≥ 1 `:failed` attempt; `next_charge_free?` — its next charge is $0 (a 100% promo code).
  """
  @type facts :: %{first_charge_declined?: boolean(), next_charge_free?: boolean()}

  @doc "Every standing kind (see `kind/1`)."
  @spec kinds() :: [:free | :active | :past_due | :cancelled | :comped | :paused]
  def kinds, do: @kinds

  @doc "Why a paused account is paused: only a superadmin hold."
  @spec pause_reasons() :: [pause_reason()]
  def pause_reasons, do: @pause_reasons

  @doc "How many days after `paid_through` a declined renewal stays usable (past due)."
  @spec grace_days() :: 1
  def grace_days, do: @grace_days

  @doc "The standing of `account` on `today`. `facts` is accepted for its callers but not read."
  @spec of(Schemas.BillingAccount.t() | nil, facts(), Date.t()) :: t()
  def of(nil, _facts, %Date{}), do: :free

  def of(account, _facts, %Date{} = today) do
    cond do
      account.held_on -> {:paused, :hold}
      account.comped -> :comped
      account.cancelled_on -> cancelled(account.access_until, today)
      # Never paid is Free. At launch the trial's multi-board owners were comped instead by the
      # `FreemiumLaunch` migration (priv/repo/migrations/*_freemium_launch.exs).
      is_nil(account.paid_through) -> :free
      true -> paid(account.paid_through, today)
    end
  end

  # A cancellation with no recorded access window (only reachable by a hand edit) grants none.
  defp cancelled(%Date{} = access_until, today) do
    if Date.after?(today, access_until), do: :free, else: {:cancelled, access_until}
  end

  defp cancelled(nil, _today), do: :free

  defp paid(paid_through, today) do
    grace_until = Date.add(paid_through, @grace_days)

    cond do
      not Date.after?(today, paid_through) -> :active
      not Date.after?(today, grace_until) -> {:past_due, grace_until}
      true -> :free
    end
  end

  @doc "A standing's kind: `{:paused, _}` → `:paused`, `{:past_due, _}` → `:past_due`, etc."
  @spec kind(t()) :: :free | :active | :past_due | :cancelled | :comped | :paused
  def kind({kind, _detail}), do: kind
  def kind(kind) when is_atom(kind), do: kind

  @doc "True exactly for the hold: every one of the owner's boards is read-only."
  @spec paused?(t()) :: boolean()
  def paused?({:paused, :hold}), do: true
  def paused?(_standing), do: false

  @doc "True for a standing with no board limit: `:active`, `{:past_due, _}`, `{:cancelled, _}`, `:comped`."
  @spec unlimited?(t()) :: boolean()
  def unlimited?(:active), do: true
  def unlimited?({:past_due, _until}), do: true
  def unlimited?({:cancelled, _access_until}), do: true
  def unlimited?(:comped), do: true
  def unlimited?(_free_or_held), do: false

  @doc "True for a standing the owner may cancel: `:active`, `{:past_due, _}`."
  @spec cancellable?(t()) :: boolean()
  def cancellable?(:active), do: true
  def cancellable?({:past_due, _until}), do: true
  def cancellable?(_standing), do: false

  @doc "True only for a cancelled plan still inside its access window."
  @spec resumable?(t()) :: boolean()
  def resumable?({:cancelled, _access_until}), do: true
  def resumable?(_standing), do: false

  @doc "True when the account has a saved card (a non-blank `card_payment_method_id`)."
  @spec card_on_file?(map()) :: boolean()
  def card_on_file?(%{card_payment_method_id: id}) when is_binary(id), do: String.trim(id) != ""
  def card_on_file?(_account), do: false
end
