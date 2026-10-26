# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Hamaca.Repo.Migrations.FreemiumLaunch) do
  "priv/repo/migrations/*_freemium_launch.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Hamaca.Migrations.FreemiumLaunchTest do
  use Hamaca.DataCase, async: true

  import Ecto.Query

  alias Hamaca.Billing
  alias Hamaca.Repo.Migrations.FreemiumLaunch, as: Migration
  alias Schemas.BillingAccount
  alias Schemas.BillingAdminEntry
  alias Schemas.BillingNotice

  @today ~D[2026-10-25]

  defp owner_with_boards(account_attrs, live_boards) do
    account = insert(:billing_account, account_attrs)
    for _ <- 1..live_boards//1, do: insert(:board, owner: account.user)
    account
  end

  defp entries_for(account) do
    Repo.all(from e in BillingAdminEntry, where: e.billing_account_id == ^account.id)
  end

  defp insert_raw_notice(account, kind, period_key) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO billing_notices (billing_account_id, kind, period_key, inserted_at)
        VALUES ($1, $2, $3, now()) RETURNING id
        """,
        [account.id, kind, period_key]
      )

    id
  end

  describe "comping trial owners" do
    test "a never-paid, uncomped, unheld owner of 2 live boards is comped with an admin entry" do
      account = owner_with_boards(%{paid_through: nil, comped: false, held_on: nil}, 2)

      assert %{comped: 1} = Migration.backfill(Repo)

      assert Repo.get!(BillingAccount, account.id).comped == true

      assert [entry] = entries_for(account)
      assert entry.action == :comp
      assert entry.actor_id == nil
      assert entry.reason == "freemium launch: trial owner with 2 boards"
    end

    test "archived and example boards don't count: a never-paid owner of 1 live board stays Free" do
      account = owner_with_boards(%{paid_through: nil, comped: false, held_on: nil}, 1)
      insert(:board, owner: account.user, archived_at: ~U[2026-10-01 00:00:00Z])
      insert(:board, owner: account.user, example_template: "bare")

      assert %{comped: 0} = Migration.backfill(Repo)

      assert Repo.get!(BillingAccount, account.id).comped == false
      assert entries_for(account) == []
    end

    test "held, already-comped and paid owners of 3 boards are left alone" do
      held = owner_with_boards(%{paid_through: nil, comped: false, held_on: ~D[2026-10-20]}, 3)
      comped = owner_with_boards(%{paid_through: nil, comped: true, held_on: nil}, 3)
      paid = owner_with_boards(%{paid_through: ~D[2026-11-20], comped: false, held_on: nil}, 3)
      before = Map.new([held, comped, paid], &{&1.id, Repo.get!(BillingAccount, &1.id)})

      assert %{comped: 0} = Migration.backfill(Repo)

      for account <- [held, comped, paid] do
        assert Repo.get!(BillingAccount, account.id) == before[account.id]
        assert entries_for(account) == []
      end
    end

    test "a second run is a no-op" do
      account = owner_with_boards(%{paid_through: nil, comped: false, held_on: nil}, 2)
      Migration.backfill(Repo)

      assert Migration.backfill(Repo) == %{comped: 0, notices_renamed: 0, notices_deleted: 0}
      assert [_one] = entries_for(account)
    end
  end

  describe "retired notice kinds" do
    test "paused becomes dropped_to_free a grace day later, trial_ending is deleted, and notices load" do
      account = insert(:billing_account)
      paused = insert_raw_notice(account, "paused", ~D[2026-10-10])
      trial_ending = insert_raw_notice(account, "trial_ending", ~D[2026-10-12])

      assert %{notices_renamed: 1, notices_deleted: 1} = Migration.backfill(Repo)

      assert %BillingNotice{kind: :dropped_to_free, period_key: ~D[2026-10-11]} =
               Repo.get!(BillingNotice, paused)

      assert Repo.get(BillingNotice, trial_ending) == nil
      assert [_notice] = Repo.all(BillingNotice)
    end
  end

  describe "the admin Users page after the launch" do
    test "the comped multi-board owner reads :comped and the single-board owner reads :free" do
      comped = owner_with_boards(%{paid_through: nil, comped: false, held_on: nil}, 2)
      free = owner_with_boards(%{paid_through: nil, comped: false, held_on: nil}, 1)
      insert(:board, owner: free.user, archived_at: ~U[2026-10-01 00:00:00Z])
      insert(:board, owner: free.user, example_template: "bare")

      Migration.backfill(Repo)

      plans = Map.new(Billing.list_admin_users(@today), &{&1.id, &1.plan})
      assert plans[comped.user_id] == :comped
      assert plans[free.user_id] == :free
    end
  end
end
