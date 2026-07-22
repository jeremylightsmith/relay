defmodule Relay.CardsResolveRefTest do
  use Relay.DataCase, async: true

  alias Relay.Cards

  setup do
    %{user: insert(:user)}
  end

  defp member_board(user, key, slug) do
    board = insert(:board, key: key, slug: slug)
    insert(:membership, board: board, user: user)
    board
  end

  defp card_on(board, ref_number) do
    stage = insert(:stage, board: board)
    insert(:card, stage: stage, ref_number: ref_number)
  end

  test "resolves a dashless ref on a board the user is a member of", %{user: user} do
    board = member_board(user, "AA", "alpha")
    card = card_on(board, 7)

    assert {:ok, resolved_board, resolved_card} = Cards.resolve_ref(user, "AA7")
    assert resolved_board.id == board.id
    assert resolved_card.id == card.id
  end

  test "also resolves the optional-dash form (old links / muscle memory)", %{user: user} do
    board = member_board(user, "AA", "alpha")
    card = card_on(board, 7)

    assert {:ok, _board, resolved} = Cards.resolve_ref(user, "AA-7")
    assert resolved.id == card.id
  end

  test "an unknown ref is :not_found", %{user: user} do
    member_board(user, "AA", "alpha")

    assert Cards.resolve_ref(user, "AA404") == {:error, :not_found}
  end

  test "a malformed ref is :not_found, not a crash", %{user: user} do
    member_board(user, "AA", "alpha")

    assert Cards.resolve_ref(user, "nonsense") == {:error, :not_found}
  end

  test "another user's card is :not_found — never leaking that it exists", %{user: user} do
    member_board(user, "AA", "alpha")
    other_board = member_board(insert(:user), "BB", "beta")
    card_on(other_board, 1)

    assert Cards.resolve_ref(user, "BB1") == {:error, :not_found}
  end

  test "a ref two same-key boards share is :ambiguous_ref, never a guess", %{user: user} do
    for slug <- ["alpha", "beta"], do: user |> member_board("RL", slug) |> card_on(1)

    assert Cards.resolve_ref(user, "RL1") == {:error, :ambiguous_ref}
  end

  test "the board slug disambiguates a shared ref", %{user: user} do
    for slug <- ["alpha", "beta"], do: user |> member_board("RL", slug) |> card_on(1)

    assert {:ok, board, _card} = Cards.resolve_ref(user, "RL1", "beta")
    assert board.slug == "beta"
  end

  test "a slug the user cannot see is :not_found", %{user: user} do
    user |> member_board("AA", "alpha") |> card_on(1)

    assert Cards.resolve_ref(user, "AA1", "someone-elses-board") == {:error, :not_found}
  end
end
