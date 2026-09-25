defmodule Relay.Repo.Migrations.WidenUsersAvatarUrl do
  use Ecto.Migration

  # Google profile photo URLs can exceed varchar(255); a first sign-in with one 500'd.
  def change do
    alter table(:users) do
      modify :avatar_url, :string, size: 2048, from: :string
    end
  end
end
