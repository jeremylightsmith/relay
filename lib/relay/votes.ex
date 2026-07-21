defmodule Relay.Votes do
  @moduledoc """
  The Votes context (RLY-69): public upvotes on cards. A vote is a unique
  `(card_id, user_id)` row; `toggle_vote/2` flips it on or off and broadcasts
  `{:vote_changed, card_id}` on the card's board topic so every open board and the
  public board re-derive the affected count live. A card's supporters are the users
  who voted; signed-out visitors on the public board see only the count.
  """

  use Boundary, deps: [Relay.Events, Relay.Repo, Schemas]

  import Ecto.Query

  alias Relay.Events
  alias Relay.Repo
  alias Schemas.Card
  alias Schemas.User
  alias Schemas.Vote

  @doc """
  Toggles `user`'s vote on `card`: inserts the row when absent (`{:ok, :added}`),
  deletes it when present (`{:ok, :removed}`). Idempotent per `(user, card)`.
  Broadcasts `{:vote_changed, card.id}` on the board topic either way.
  """
  def toggle_vote(%User{id: user_id}, %Card{id: card_id, board_id: board_id}) do
    result =
      case Repo.get_by(Vote, card_id: card_id, user_id: user_id) do
        nil ->
          %Vote{card_id: card_id, user_id: user_id}
          |> Vote.changeset()
          |> Repo.insert(on_conflict: :nothing)

          {:ok, :added}

        %Vote{} = vote ->
          {:ok, _} = Repo.delete(vote)
          {:ok, :removed}
      end

    Events.broadcast(board_id, {:vote_changed, card_id})
    result
  end

  @doc "True when `user` has voted on `card`."
  def voted?(%User{id: user_id}, %Card{id: card_id}) do
    Repo.exists?(from v in Vote, where: v.user_id == ^user_id and v.card_id == ^card_id)
  end

  @doc "The subset of `card_ids` that `user` has voted on, as a MapSet (board render helper)."
  def voted_card_ids(%User{id: user_id}, card_ids) when is_list(card_ids) do
    from(v in Vote,
      where: v.user_id == ^user_id and v.card_id in ^card_ids,
      select: v.card_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "Vote count for one card."
  def count(card_id) when is_integer(card_id) do
    Repo.one(from v in Vote, where: v.card_id == ^card_id, select: count(v.id))
  end

  @doc "`%{card_id => count}` for the given ids in one grouped query (no N+1); missing ids omitted."
  def counts_for_cards(card_ids) when is_list(card_ids) do
    from(v in Vote,
      where: v.card_id in ^card_ids,
      group_by: v.card_id,
      select: {v.card_id, count(v.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Up to `limit` supporters of `card`, most-recent first, plus the total count:
  `{[%User{}], total}`. Drives the drawer's PUBLIC SUPPORT block and the public
  detail modal's supporter list.
  """
  def supporters(%Card{id: card_id}, limit) when is_integer(limit) do
    users =
      Repo.all(
        from v in Vote,
          join: u in assoc(v, :user),
          where: v.card_id == ^card_id,
          order_by: [desc: v.inserted_at, desc: v.id],
          limit: ^limit,
          select: u
      )

    {users, count(card_id)}
  end
end
