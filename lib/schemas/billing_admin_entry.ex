defmodule Schemas.BillingAdminEntry do
  @moduledoc """
  One superadmin action on a billing account (RE463) — the account's admin history, shown in the
  `/admin/users` side panel. Append-only: written once by `Hamaca.Billing.Admin`'s one entry
  writer, in the same transaction as the account change (a retry's after the charge returns),
  and never updated or deleted.

  `action` is one of `actions/0`. `reason` is the admin's note (hold and extend require one);
  `days` the extension; `paid_through_before` / `paid_through_after` the account's
  `paid_through` either side of an extend or a retry. `actor` is the superadmin, nilified if
  that user is deleted.

  `billing_account_id` and `actor_id` are set programmatically on the struct, never cast.
  """

  use Ecto.Schema

  @actions [:comp, :uncomp, :hold, :lift_hold, :extend, :retry_charge]

  schema "billing_admin_entries" do
    field :action, Ecto.Enum, values: @actions
    field :reason, :string
    field :days, :integer
    field :paid_through_before, :date
    field :paid_through_after, :date

    belongs_to :billing_account, Schemas.BillingAccount
    belongs_to :actor, Schemas.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc "Every admin action, in the order the side panel offers them."
  @spec actions() :: [:comp | :uncomp | :hold | :lift_hold | :extend | :retry_charge]
  def actions, do: @actions
end
