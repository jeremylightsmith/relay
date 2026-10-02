defmodule Relay.Repo.Migrations.AddMockupsToCards do
  use Ecto.Migration

  # RE370 — HTML mockups attached to a card: an ordered list of %{"url", "caption"} maps whose
  # url is always an /attachments/<id> path of an HTML attachment on the same card. Nullable;
  # nil = no mockups. Written only through Relay.Cards.set_mockups/2.
  #
  # Renumbered from 20261001130000, which RE367's migration also used (a fresh DB refuses a
  # duplicated version). `add_if_not_exists` keeps a dev DB that already ran it under the old
  # version from failing on the re-add.
  def up do
    alter table(:cards) do
      add_if_not_exists :mockups, {:array, :map}
    end
  end

  def down do
    alter table(:cards) do
      remove_if_exists :mockups
    end
  end
end
