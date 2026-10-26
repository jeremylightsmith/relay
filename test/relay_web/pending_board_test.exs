defmodule RelayWeb.PendingBoardTest do
  @moduledoc """
  RE472: the signed, short-lived token that carries a not-yet-created board through Checkout.
  """
  use Relay.DataCase, async: true

  alias RelayWeb.PendingBoard

  @attrs %{name: "Acme Checkout", key: "AC", template: "design-led"}

  setup do
    %{user: insert(:user)}
  end

  test "1. a signed token verifies back to its board for its user", %{user: user} do
    user_id = user.id

    assert {:ok,
            %{
              user_id: ^user_id,
              name: "Acme Checkout",
              key: "AC",
              template: "design-led",
              copy_from: nil,
              issued_at: issued_at
            } = pending} = PendingBoard.verify(PendingBoard.sign(user, @attrs), user)

    assert map_size(pending) == 6
    assert is_integer(issued_at)
    assert abs(System.system_time(:second) - issued_at) <= 5
  end

  test "1. a copy token carries copy_from and no template", %{user: user} do
    token = PendingBoard.sign(user, %{name: "Copy Two", key: "CT", copy_from: "some-board"})

    assert {:ok, %{template: nil, copy_from: "some-board"}} = PendingBoard.verify(token, user)
  end

  test "2. a token signed for another user is refused", %{user: user} do
    other = insert(:user)

    assert PendingBoard.verify(PendingBoard.sign(user, @attrs), other) == {:error, :wrong_user}
  end

  test "3. a tampered token and a missing one are invalid", %{user: user} do
    token = PendingBoard.sign(user, @attrs)
    tampered = RelayWeb.TokenHelpers.tamper(token)

    assert PendingBoard.verify(tampered, user) == {:error, :invalid}
    assert PendingBoard.verify(nil, user) == {:error, :invalid}
  end

  test "4. a token older than max_age/0 has expired", %{user: user} do
    signed_at = System.system_time(:second) - PendingBoard.max_age() - 60
    token = PendingBoard.sign(user, @attrs, signed_at: signed_at)

    assert PendingBoard.verify(token, user) == {:error, :expired}
    assert PendingBoard.max_age() == 86_400
  end
end
