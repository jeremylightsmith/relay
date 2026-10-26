defmodule Relay.Repo.Migrations.AddFreeBoardChoiceToBillingAccounts do
  # RE471: the owner's pick of which counted board stays editable on Free (nil = the most
  # recently active, RE469's rule — no backfill), and when the one-time "Which board stays
  # editable?" prompt was shown (cleared on leaving Free). Calls no app modules.
  use Ecto.Migration

  def change do
    alter table(:billing_accounts) do
      add :free_board_id, references(:boards, on_delete: :nilify_all)
      add :free_board_prompted_at, :utc_datetime
    end

    create index(:billing_accounts, [:free_board_id])
  end
end
