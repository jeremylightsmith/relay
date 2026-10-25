defmodule Schemas.BillingNotice do
  @moduledoc """
  One billing email sent to an account's owner (RE464, ADR 0012 decision 10), recorded before it
  is sent.

  The unique index `billing_notices_once` on `(billing_account_id, kind, period_key)` is what
  makes each email go out at most once per period: `period_key` is the declined attempt's
  `period_start` for `:card_declined`, and the first Free day (`paid_through + grace + 1`) for
  `:dropped_to_free`. (The pre-Free `:trial_ending` and `:paused` rows are rewritten by RE469's
  launch migration.)

  `billing_account_id` is set programmatically on the struct, never cast from input.
  """

  use Ecto.Schema

  @kinds [:card_declined, :dropped_to_free]

  schema "billing_notices" do
    field :kind, Ecto.Enum, values: @kinds
    field :period_key, :date

    belongs_to :billing_account, Schemas.BillingAccount

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc "Every billing email: a declined card, the plan dropped to Free."
  @spec kinds() :: [:card_declined | :dropped_to_free]
  def kinds, do: @kinds
end
