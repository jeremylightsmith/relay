defmodule Schemas.BillingNotice do
  @moduledoc """
  One billing email sent to an account's owner (RE464, ADR 0012 decision 10), recorded before it
  is sent.

  The unique index `billing_notices_once` on `(billing_account_id, kind, period_key)` is what
  makes each email go out at most once per period: `period_key` is the trial's last day for
  `:trial_ending`, the declined attempt's `period_start` for `:card_declined`, and the first
  unpaid day for `:paused`.

  `billing_account_id` is set programmatically on the struct, never cast from input.
  """

  use Ecto.Schema

  @kinds [:trial_ending, :card_declined, :paused]

  schema "billing_notices" do
    field :kind, Ecto.Enum, values: @kinds
    field :period_key, :date

    belongs_to :billing_account, Schemas.BillingAccount

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc "Every billing email: the trial ending, a declined card, the plan paused."
  @spec kinds() :: [:trial_ending | :card_declined | :paused]
  def kinds, do: @kinds
end
