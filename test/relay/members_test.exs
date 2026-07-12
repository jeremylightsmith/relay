defmodule Relay.MembersTest do
  use Relay.DataCase, async: true

  alias Relay.Members
  alias Relay.Repo
  alias Schemas.Membership
  alias Ueberauth.Auth.Info

  describe "invite/2" do
    test "creates an invited (user-less) row for an unregistered email" do
      board = insert(:board)

      assert {:ok, membership} = Members.invite(board, "New.Person@Example.com")
      assert membership.user_id == nil
      assert membership.email == "new.person@example.com"
      assert Membership.invited?(membership)
    end

    test "resolves immediately when the email already belongs to a user" do
      board = insert(:board)
      user = insert(:user, email: "ada@example.com")

      assert {:ok, membership} = Members.invite(board, "  Ada@Example.com ")
      assert membership.user_id == user.id
      refute Membership.invited?(membership)
    end

    test "returns {:error, :already_member} on a duplicate invite" do
      board = insert(:board)
      {:ok, _} = Members.invite(board, "dup@example.com")

      assert {:error, :already_member} = Members.invite(board, "DUP@example.com")
    end

    test "returns {:error, changeset} for a blank email" do
      board = insert(:board)
      assert {:error, %Ecto.Changeset{}} = Members.invite(board, "   ")
    end

    test "resolves immediately for a user whose stored email came from the provider with mixed case" do
      board = insert(:board)

      auth = %Ueberauth.Auth{
        provider: :google,
        uid: "google-uid-ada",
        info: %Info{email: "  Ada@Example.com ", name: "Ada Lovelace", image: nil}
      }

      {:ok, user} = Relay.Accounts.upsert_user_from_google(auth)

      assert {:ok, membership} = Members.invite(board, "ada@example.com")
      assert membership.user_id == user.id
      refute Membership.invited?(membership)
    end
  end

  describe "resolve_invites_for_user/1" do
    test "attaches the user to matching invited rows and is idempotent" do
      board = insert(:board)
      {:ok, invited} = Members.invite(board, "later@example.com")
      assert invited.user_id == nil

      user = insert(:user, email: "later@example.com")
      assert :ok = Members.resolve_invites_for_user(user)
      assert Repo.get!(Membership, invited.id).user_id == user.id

      # idempotent — running again changes nothing
      assert :ok = Members.resolve_invites_for_user(user)
      assert Repo.get!(Membership, invited.id).user_id == user.id
    end

    test "matches when the user's stored email was normalized from a mixed-case provider address" do
      board = insert(:board)
      {:ok, invited} = Members.invite(board, "later@example.com")

      auth = %Ueberauth.Auth{
        provider: :google,
        uid: "google-uid-later",
        info: %Info{email: "  Later@Example.com ", name: "Later Person", image: nil}
      }

      {:ok, user} = Relay.Accounts.upsert_user_from_google(auth)

      assert :ok = Members.resolve_invites_for_user(user)
      assert Repo.get!(Membership, invited.id).user_id == user.id
    end
  end

  describe "list_members/1 and member?/2" do
    test "lists members with users preloaded, including invited rows" do
      board = insert(:board)
      alice = insert(:user, name: "Alice")
      insert(:membership, board: board, user: alice, email: alice.email)
      {:ok, _invited} = Members.invite(board, "pending@example.com")

      members = Members.list_members(board)
      assert length(members) == 2
      assert Enum.any?(members, &(&1.user && &1.user.name == "Alice"))
      assert Enum.any?(members, &(&1.user_id == nil and &1.email == "pending@example.com"))
    end

    test "member?/2 is true only for a resolved membership" do
      board = insert(:board)
      member = insert(:user)
      insert(:membership, board: board, user: member, email: member.email)

      assert Members.member?(board, member)
      refute Members.member?(board, insert(:user))
    end
  end

  describe "remove/1" do
    test "deletes the row and broadcasts {:member_removed, user_id}" do
      board = insert(:board)
      member = insert(:user)
      membership = insert(:membership, board: board, user: member, email: member.email)

      Relay.Events.subscribe(board.id)
      assert {:ok, _} = Members.remove(membership)

      assert_receive {:member_removed, user_id}
      assert user_id == member.id
      refute Repo.get(Membership, membership.id)
    end
  end
end
