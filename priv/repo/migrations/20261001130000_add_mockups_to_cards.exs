defmodule Relay.Repo.Migrations.AddMockupsToCards do
  use Ecto.Migration

  # RE370 — HTML mockups attached to a card: an ordered list of %{"url", "caption"} maps whose
  # url is always an /attachments/<id> path of an HTML attachment on the same card. Nullable;
  # nil = no mockups. Written only through Relay.Cards.set_mockups/2.
  def change do
    alter table(:cards) do
      add :mockups, {:array, :map}
    end
  end
end
