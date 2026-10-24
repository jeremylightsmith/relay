defmodule Relay.Billing.Standing do
  @moduledoc """
  The standing a billing account is in today (RE460, ADR 0012): pure, derived from the account's
  stored facts, never stored itself. A port of Throughway's `Plans.Standing.of/3` with one price,
  `paid_through` standing in for the plan state and a `grace_days/0` grace.

  The first matching rule wins:

    1. no account, or one with neither `trial_ends_on` nor `paid_through` → `:trial`
       (pre-backfill: unrestricted);
    2. `held_on` set → `{:paused, :hold}`;
    3. `comped` → `:comped`;
    4. `cancelled_on` set → `{:cancelled, access_until}` through `access_until`, then
       `{:paused, :cancelled}`;
    5. never paid: `:trial` through `trial_ends_on`, and after it while a card is on file and the
       first charge has not been declined (awaiting the clock); else `{:paused, :trial_ended}`;
    6. paid: `:active` through `paid_through`, `{:past_due, paid_through + grace_days()}` during
       the grace, then `{:paused, :unpaid}`.
  """

  @kinds [:trial, :active, :past_due, :cancelled, :comped, :paused]
  @pause_reasons [:trial_ended, :unpaid, :cancelled, :hold]
  @trial_days 30
  @grace_days 1

  @type pause_reason :: :trial_ended | :unpaid | :cancelled | :hold
  @type t ::
          :trial
          | :active
          | :comped
          | {:past_due, until :: Date.t()}
          | {:cancelled, access_until :: Date.t()}
          | {:paused, pause_reason()}
  @typedoc "`first_charge_declined?`: the account has ≥ 1 `:failed` attempt and `paid_through` is nil."
  @type facts :: %{first_charge_declined?: boolean()}

  @doc "Every standing kind (see `kind/1`)."
  @spec kinds() :: [:trial | :active | :past_due | :cancelled | :comped | :paused]
  def kinds, do: @kinds

  @doc "Why a paused account is paused."
  @spec pause_reasons() :: [pause_reason()]
  def pause_reasons, do: @pause_reasons

  @doc "How long a trial runs, in days. A trial gets no grace."
  @spec trial_days() :: 30
  def trial_days, do: @trial_days

  @doc "How many days after `paid_through` a declined renewal stays usable (past due)."
  @spec grace_days() :: 1
  def grace_days, do: @grace_days

  @doc "The standing of `account` on `today`, given `facts` about its attempts."
  @spec of(Schemas.BillingAccount.t() | nil, facts(), Date.t()) :: t()
  def of(nil, _facts, %Date{}), do: :trial
  def of(%{trial_ends_on: nil, paid_through: nil}, _facts, %Date{}), do: :trial

  def of(account, facts, %Date{} = today) do
    cond do
      account.held_on -> {:paused, :hold}
      account.comped -> :comped
      account.cancelled_on -> cancelled(account.access_until, today)
      is_nil(account.paid_through) -> never_paid(account, facts, today)
      true -> paid(account.paid_through, today)
    end
  end

  defp cancelled(%Date{} = access_until, today) do
    if Date.after?(today, access_until), do: {:paused, :cancelled}, else: {:cancelled, access_until}
  end

  # A cancellation with no recorded access window (only reachable by a hand edit) grants none.
  defp cancelled(nil, _today), do: {:paused, :cancelled}

  defp never_paid(account, facts, today) do
    cond do
      not Date.after?(today, account.trial_ends_on) -> :trial
      card_on_file?(account) and not facts.first_charge_declined? -> :trial
      true -> {:paused, :trial_ended}
    end
  end

  defp paid(paid_through, today) do
    grace_until = Date.add(paid_through, @grace_days)

    cond do
      not Date.after?(today, paid_through) -> :active
      not Date.after?(today, grace_until) -> {:past_due, grace_until}
      true -> {:paused, :unpaid}
    end
  end

  @doc "A standing's kind: `{:paused, _}` → `:paused`, `{:past_due, _}` → `:past_due`, etc."
  @spec kind(t()) :: :trial | :active | :past_due | :cancelled | :comped | :paused
  def kind({kind, _detail}), do: kind
  def kind(kind) when is_atom(kind), do: kind

  @doc "True exactly for a paused standing: the owner's boards are read-only."
  @spec paused?(t()) :: boolean()
  def paused?({:paused, _reason}), do: true
  def paused?(_standing), do: false

  @doc "True for a standing the owner may cancel: `:trial`, `:active`, `{:past_due, _}`."
  @spec cancellable?(t()) :: boolean()
  def cancellable?(:trial), do: true
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
