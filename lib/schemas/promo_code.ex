defmodule Schemas.PromoCode do
  @moduledoc """
  A promo code (RE462, ADR 0012): `percent_off` (1–100) off an account's next `months` **paid**
  months. `code` is case-insensitive and unique — stored trimmed and upper-cased.
  `max_redemptions` (optional) caps how many accounts may hold it; `expires_on` (optional) is the
  last day it redeems. How many accounts hold a code is counted from
  `billing_accounts.promo_code_id`, never stored here.

  `disabled_at` is set programmatically by `Hamaca.Billing.disable_promo_code/2`, never cast.
  Every write goes through `Hamaca.Billing`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @code_format ~r/\A[A-Z0-9_-]{3,32}\z/

  schema "promo_codes" do
    field :code, :string
    field :percent_off, :integer
    field :months, :integer
    field :max_redemptions, :integer
    field :expires_on, :date
    field :disabled_at, :utc_datetime

    has_many :billing_accounts, Schemas.BillingAccount

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "Casts and validates a code's admin-editable fields (never `disabled_at`); trims and upper-cases `code`."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(promo_code, attrs) do
    promo_code
    |> cast(attrs, [:code, :percent_off, :months, :max_redemptions, :expires_on])
    |> update_change(:code, &(&1 |> String.trim() |> String.upcase()))
    |> validate_required([:code, :percent_off, :months])
    |> validate_format(:code, @code_format, message: "use 3–32 letters, digits, - or _")
    |> validate_number(:percent_off, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> validate_number(:months, greater_than_or_equal_to: 1)
    |> validate_number(:max_redemptions, greater_than_or_equal_to: 1)
    |> unique_constraint(:code, message: "already exists")
  end
end
