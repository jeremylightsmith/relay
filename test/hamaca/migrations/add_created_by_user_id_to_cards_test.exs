# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Hamaca.Repo.Migrations.AddCreatedByUserIdToCards) do
  "priv/repo/migrations/*_add_created_by_user_id_to_cards.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Hamaca.Migrations.AddCreatedByUserIdToCardsTest do
  use Hamaca.DataCase, async: true

  alias Hamaca.Repo.Migrations.AddCreatedByUserIdToCards, as: Migration
  alias Schemas.Card

  test "stamps a user-created card's requester from its :created activity, skipping agent cards" do
    u = insert(:user)
    c1 = insert(:card, created_by_user_id: nil)
    insert(:activity, card: c1, type: :created, meta: %{}, user: u)
    c2 = insert(:card)
    insert(:activity, card: c2, type: :created, meta: %{})

    assert Migration.backfill(Repo) == 1
    assert Repo.get!(Card, c1.id).created_by_user_id == u.id
    assert Repo.get!(Card, c2.id).created_by_user_id == nil
  end

  test "never overwrites a requester that is already set (idempotent)" do
    u1 = insert(:user)
    u2 = insert(:user)
    card = insert(:card, created_by_user_id: u2.id)
    insert(:activity, card: card, type: :created, meta: %{}, user: u1)

    assert Migration.backfill(Repo) == 0
    assert Repo.get!(Card, card.id).created_by_user_id == u2.id
  end

  test "a user :created row whose user was deleted leaves the card without a requester" do
    card = insert(:card)
    insert(:activity, card: card, type: :created, meta: %{}, actor_type: :user, user_id: nil)

    assert Migration.backfill(Repo) == 0
    assert Repo.get!(Card, card.id).created_by_user_id == nil
  end
end
