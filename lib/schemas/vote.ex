defmodule Schemas.Vote do
  @moduledoc """
  One user's upvote of one card (RLY-69). A vote is a unique `(card_id, user_id)`
  row — `Relay.Votes.toggle_vote/2` inserts or deletes it. Both ids are set
  programmatically, never cast from input; the changeset only carries the
  `unique_constraint` so a double-vote surfaces as a changeset error rather than a
  raw DB crash.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "votes" do
    belongs_to :card, Schemas.Card
    belongs_to :user, Schemas.User

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for a vote. `card_id`/`user_id` must already be set on the struct."
  def changeset(vote, _attrs \\ %{}) do
    vote
    |> cast(%{}, [])
    |> unique_constraint([:card_id, :user_id])
  end
end
