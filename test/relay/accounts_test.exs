defmodule Relay.AccountsTest do
  use Relay.DataCase, async: true

  alias Relay.Accounts
  alias Schemas.Scope
  alias Schemas.User
  alias Ueberauth.Auth.Extra

  defp google_auth(attrs) do
    %Ueberauth.Auth{
      provider: :google,
      uid: Map.get(attrs, :uid, "google-uid-123"),
      info: %Ueberauth.Auth.Info{
        email: Map.get(attrs, :email, "ada@example.com"),
        name: Map.get(attrs, :name, "Ada Lovelace"),
        image: Map.get(attrs, :image, "https://example.com/ada.png")
      },
      extra: %Extra{
        raw_info: %{user: Map.get(attrs, :userinfo, %{"email_verified" => true})}
      }
    }
  end

  describe "upsert_user_from_google/1" do
    test "stores a Google avatar URL longer than 255 characters" do
      image = "https://lh3.googleusercontent.com/a/" <> String.duplicate("x", 1000)

      assert {:ok, %User{} = user} = Accounts.upsert_user_from_google(google_auth(%{image: image}))
      assert user.avatar_url == image
    end

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

    test "links a different google account to the existing user that owns the verified email" do
      existing = insert(:user, email: "taken@example.com")

      assert {:ok, %User{} = user} =
               Accounts.upsert_user_from_google(google_auth(%{uid: "other-uid", email: "taken@example.com"}))

      assert user.id == existing.id
      assert user.provider_uid == existing.provider_uid
      assert Repo.aggregate(User, :count) == 1
    end

    test "normalizes the provider's email casing/whitespace so it matches invite lookups" do
      assert {:ok, %User{} = user} =
               Accounts.upsert_user_from_google(google_auth(%{email: "  Ada@Example.com "}))

      assert user.email == "ada@example.com"
    end

    test "accepts a string \"true\" email_verified claim" do
      assert {:ok, %User{}} =
               Accounts.upsert_user_from_google(google_auth(%{userinfo: %{"email_verified" => "true"}}))
    end

    test "rejects an unverified email without touching the DB" do
      for userinfo <- [%{"email_verified" => false}, %{"email_verified" => "false"}, %{}] do
        assert {:error, :email_unverified} =
                 Accounts.upsert_user_from_google(google_auth(%{userinfo: userinfo}))
      end

      assert Repo.aggregate(User, :count) == 0
    end

    test "treats a missing extra / raw_info / user as unverified" do
      base = google_auth(%{})

      for auth <- [
            %{base | extra: nil},
            %{base | extra: %Extra{raw_info: nil}},
            %{base | extra: %Extra{raw_info: %{}}},
            %{base | extra: %Extra{raw_info: %{user: nil}}}
          ] do
        assert {:error, :email_unverified} = Accounts.upsert_user_from_google(auth)
      end

      assert Repo.aggregate(User, :count) == 0
    end

    test "does not refresh an existing user's profile from an unverified sign-in" do
      {:ok, user} = Accounts.upsert_user_from_google(google_auth(%{}))

      assert {:error, :email_unverified} =
               Accounts.upsert_user_from_google(
                 google_auth(%{email: "squat@example.com", userinfo: %{"email_verified" => false}})
               )

      assert Repo.get!(User, user.id).email == "ada@example.com"
    end
  end

  describe "upsert_user_from_provider/2" do
    @claims %{
      provider: "google",
      provider_uid: "prov-uid-1",
      email: "grace@example.com",
      name: "Grace Hopper",
      avatar_url: "https://example.com/grace.png"
    }

    test "inserts a new user on first sign-in, keyed on provider_uid" do
      assert {:ok, %User{} = user} = Accounts.upsert_user_from_provider(@claims)
      assert user.provider == "google"
      assert user.provider_uid == "prov-uid-1"
      assert user.email == "grace@example.com"
      assert user.name == "Grace Hopper"
      assert user.avatar_url == "https://example.com/grace.png"
    end

    test "refreshes profile but keeps identity on a return sign-in" do
      {:ok, first} = Accounts.upsert_user_from_provider(@claims)

      assert {:ok, second} =
               Accounts.upsert_user_from_provider(%{
                 @claims
                 | name: "Grace M. Hopper",
                   email: "grace@navy.example",
                   avatar_url: "https://example.com/new.png"
               })

      assert second.id == first.id
      assert second.name == "Grace M. Hopper"
      assert second.email == "grace@navy.example"
      assert second.avatar_url == "https://example.com/new.png"
      assert Repo.aggregate(User, :count) == 1
    end

    test "normalizes the provider email casing/whitespace" do
      assert {:ok, user} =
               Accounts.upsert_user_from_provider(%{@claims | email: "  Grace@Example.com "})

      assert user.email == "grace@example.com"
    end

    test "an email match signs in the existing user without touching its identity or profile" do
      existing =
        insert(:user,
          provider: "google",
          provider_uid: "g-1",
          email: "alice@example.com",
          name: "Alice Google",
          avatar_url: "https://example.com/a.png"
        )

      assert {:ok, %User{} = user} =
               Accounts.upsert_user_from_provider(%{
                 provider: "apple",
                 provider_uid: "apple-sub-1",
                 email: "alice@example.com",
                 name: nil,
                 avatar_url: nil
               })

      assert user.id == existing.id
      assert user.provider == "google"
      assert user.provider_uid == "g-1"
      assert user.name == "Alice Google"
      assert user.avatar_url == "https://example.com/a.png"
      assert Repo.aggregate(User, :count) == 1
    end

    test "an email match refreshes non-nil name and avatar but keeps the stored identity" do
      existing =
        insert(:user,
          provider: "apple",
          provider_uid: "apple-sub-1",
          email: "bob@example.com",
          name: "Bob Apple",
          avatar_url: nil
        )

      assert {:ok, %User{} = user} =
               Accounts.upsert_user_from_provider(%{
                 provider: "google",
                 provider_uid: "g-2",
                 email: "bob@example.com",
                 name: "Bob G",
                 avatar_url: "https://example.com/b.png"
               })

      assert user.id == existing.id
      assert user.provider == "apple"
      assert user.provider_uid == "apple-sub-1"
      assert user.name == "Bob G"
      assert user.avatar_url == "https://example.com/b.png"
      assert Repo.aggregate(User, :count) == 1
    end

    test "the email match normalizes the claimed email" do
      existing = insert(:user, email: "alice@example.com")

      assert {:ok, %User{} = user} =
               Accounts.upsert_user_from_provider(%{
                 @claims
                 | provider_uid: "new-uid",
                   email: "  Alice@Example.COM "
               })

      assert user.id == existing.id
      assert Repo.aggregate(User, :count) == 1
    end

    test "a nil claim never wipes a stored value on a provider_uid match" do
      insert(:user, provider: "apple", provider_uid: "apple-sub-1", name: "Carol", avatar_url: nil)

      assert {:ok, %User{} = user} =
               Accounts.upsert_user_from_provider(%{
                 provider: "apple",
                 provider_uid: "apple-sub-1",
                 email: "carol@example.com",
                 name: nil,
                 avatar_url: nil
               })

      assert user.name == "Carol"
      assert user.email == "carol@example.com"
    end

    test "the name opt is the inserted user's name when the claims carry none" do
      assert {:ok, %User{} = user} =
               Accounts.upsert_user_from_provider(
                 %{provider: "apple", provider_uid: "apple-sub-9", email: "dan@example.com", name: nil, avatar_url: nil},
                 name: "Dan Brown"
               )

      assert user.provider == "apple"
      assert user.provider_uid == "apple-sub-9"
      assert user.name == "Dan Brown"
    end

    test "the claims' own name wins over the name opt on insert" do
      assert {:ok, %User{} = user} =
               Accounts.upsert_user_from_provider(%{@claims | name: "Claims Name"}, name: "Opt Name")

      assert user.name == "Claims Name"
    end

    test "the name opt is never applied to a user matched by email" do
      existing = insert(:user, email: "eve@example.com", name: "Eve Original")

      assert {:ok, %User{} = user} =
               Accounts.upsert_user_from_provider(
                 %{provider: "apple", provider_uid: "apple-sub-5", email: "eve@example.com", name: nil, avatar_url: nil},
                 name: "Eve From Apple"
               )

      assert user.id == existing.id
      assert user.name == "Eve Original"
    end

    test "a return visit whose new email belongs to someone else is rejected" do
      insert(:user, provider_uid: "g-1", email: "one@example.com")
      insert(:user, email: "two@example.com")

      assert {:error, changeset} =
               Accounts.upsert_user_from_provider(%{
                 provider: "google",
                 provider_uid: "g-1",
                 email: "two@example.com",
                 name: "X",
                 avatar_url: nil
               })

      assert errors_on(changeset) == %{email: ["has already been taken"]}
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
