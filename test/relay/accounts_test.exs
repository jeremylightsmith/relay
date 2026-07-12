defmodule Relay.AccountsTest do
  use Relay.DataCase, async: true

  alias Relay.Accounts
  alias Schemas.Scope
  alias Schemas.User

  defp google_auth(attrs) do
    %Ueberauth.Auth{
      provider: :google,
      uid: Map.get(attrs, :uid, "google-uid-123"),
      info: %Ueberauth.Auth.Info{
        email: Map.get(attrs, :email, "ada@example.com"),
        name: Map.get(attrs, :name, "Ada Lovelace"),
        image: Map.get(attrs, :image, "https://example.com/ada.png")
      }
    }
  end

  describe "upsert_user_from_google/1" do
    test "creates a user on first sign-in" do
      assert {:ok, %User{} = user} = Accounts.upsert_user_from_google(google_auth(%{}))
      assert user.email == "ada@example.com"
      assert user.name == "Ada Lovelace"
      assert user.avatar_url == "https://example.com/ada.png"
      assert user.provider == "google"
      assert user.provider_uid == "google-uid-123"
    end

    test "reuses and updates the user on later sign-ins with the same provider_uid" do
      {:ok, user} = Accounts.upsert_user_from_google(google_auth(%{}))

      assert {:ok, updated} =
               Accounts.upsert_user_from_google(
                 google_auth(%{
                   name: "Ada K. Lovelace",
                   email: "ada@newmail.example",
                   image: "https://example.com/new.png"
                 })
               )

      assert updated.id == user.id
      assert updated.name == "Ada K. Lovelace"
      assert updated.email == "ada@newmail.example"
      assert updated.avatar_url == "https://example.com/new.png"
      assert Repo.aggregate(User, :count) == 1
    end

    test "enforces email uniqueness across different google accounts" do
      insert(:user, email: "taken@example.com")

      assert {:error, changeset} =
               Accounts.upsert_user_from_google(google_auth(%{uid: "other-uid", email: "taken@example.com"}))

      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end

    test "normalizes the provider's email casing/whitespace so it matches invite lookups" do
      assert {:ok, %User{} = user} =
               Accounts.upsert_user_from_google(google_auth(%{email: "  Ada@Example.com "}))

      assert user.email == "ada@example.com"
    end
  end

  describe "get_user/1" do
    test "returns the user for an id" do
      user = insert(:user)
      assert Accounts.get_user(user.id).id == user.id
    end

    test "returns nil for an unknown id" do
      assert Accounts.get_user(-1) == nil
    end
  end

  describe "ensure_dev_user!/0" do
    test "creates the dev user on first call and reuses it after" do
      user = Accounts.ensure_dev_user!()

      assert user.email == "dev@relay.local"
      assert user.provider == "dev"
      assert user.provider_uid == "dev-user"
      assert Accounts.ensure_dev_user!().id == user.id
      assert Repo.aggregate(User, :count) == 1
    end
  end

  describe "Scope.for_user/1" do
    test "wraps a user" do
      user = insert(:user)
      assert %Scope{user: ^user} = Scope.for_user(user)
    end

    test "returns nil for nil" do
      assert Scope.for_user(nil) == nil
    end
  end
end
