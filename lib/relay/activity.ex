defmodule Relay.Activity do
  @moduledoc """
  The Activity context: a card's conversational and audit record —
  comments posted by humans or the AI, and activity entries logged for
  every meaningful card change (MMF 07).

  An "actor" is either the single Relay AI agent (`:agent`) or a user
  (`{:user, user_id}`) — the same concept `Relay.Cards` uses for owners.
  This context never calls `Relay.Cards`; `Cards` depends on it to log.
  """

  use Boundary, deps: [Relay.Events, Relay.Repo, Schemas]

  import Ecto.Query

  alias Relay.Events
  alias Relay.Repo
  alias Schemas.Card
  alias Schemas.Comment

  @doc """
  Posts a comment on `card` from `attrs` — `:actor`
  (`:agent | {:user, user_id}`, programmatic), `:body` (the only
  user-supplied field), and an optional `:kind`
  (`:comment | :question | :changes_requested`, programmatic, defaults to
  `:comment`) — returning `{:ok, comment}` with the author preloaded or
  `{:error, changeset}`.
  """
  def add_comment(%Card{} = card, %{actor: actor} = attrs) do
    {actor_type, user_id} = split_actor(actor)

    %Comment{
      card_id: card.id,
      actor_type: actor_type,
      user_id: user_id,
      kind: Map.get(attrs, :kind, :comment)
    }
    |> Comment.changeset(Map.take(attrs, [:body]))
    |> Repo.insert()
    |> preload_user()
    |> broadcast_appended(card)
  end

  @doc """
  Appends an activity entry to `card`'s log from `attrs` — `:type`
  (`:created | :moved | :status_changed | :owners_changed | :commented | :approved | :rejected | :needs_input | :input_answered`),
  `:actor` (`:agent | {:user, user_id}`), and optional `:meta` (a map
  with STRING keys and primitive values, stored as jsonb; defaults to
  `%{}`) — returning `{:ok, activity}` with the actor preloaded or
  `{:error, changeset}`.
  """
  def log(%Card{} = card, %{type: type, actor: actor} = attrs) do
    {actor_type, user_id} = split_actor(actor)

    %Schemas.Activity{
      card_id: card.id,
      type: type,
      meta: Map.get(attrs, :meta, %{}),
      actor_type: actor_type,
      user_id: user_id
    }
    |> Schemas.Activity.changeset()
    |> Repo.insert()
    |> preload_user()
    |> broadcast_appended(card)
  end

  @doc """
  The card's full timeline: its comments and activity entries merged
  into one list, ascending by `inserted_at` (comments sort before
  activity entries logged in the same second; within a source, ties
  break by id), each entry with its `:user` preloaded (`nil` for the
  agent).
  """
  def list_timeline(%Card{id: card_id}) do
    comments =
      Repo.all(
        from c in Comment,
          where: c.card_id == ^card_id,
          order_by: [asc: c.inserted_at, asc: c.id],
          preload: :user
      )

    activities =
      Repo.all(
        from a in Schemas.Activity,
          where: a.card_id == ^card_id,
          order_by: [asc: a.inserted_at, asc: a.id],
          preload: :user
      )

    Enum.sort_by(comments ++ activities, & &1.inserted_at, DateTime)
  end

  @doc """
  The card's conversation: its comments only, ascending by `inserted_at`
  (ties break by id), so the newest sits at the bottom — chat convention,
  with the composer pinned below. Each comment has its `:user` preloaded
  (`nil` for the agent).
  """
  def list_conversation(%Card{id: card_id}) do
    Repo.all(
      from c in Comment,
        where: c.card_id == ^card_id,
        order_by: [asc: c.inserted_at, asc: c.id],
        preload: :user
    )
  end

  @doc """
  The card's activity log: its activity entries only, descending by
  `inserted_at` (ties break by id), so the newest sits at the top. Each
  entry has its `:user` preloaded (`nil` for the agent).
  """
  def list_activity(%Card{id: card_id}) do
    Repo.all(
      from a in Schemas.Activity,
        where: a.card_id == ^card_id,
        order_by: [desc: a.inserted_at, desc: a.id],
        preload: :user
    )
  end

  # MMF 18: announce the new timeline entry to every open board session.
  # Receivers apply the payload struct directly (no DB re-read), so this
  # is safe even when the log happens inside a caller's transaction.
  defp broadcast_appended({:ok, entry} = result, %Card{} = card) do
    Events.broadcast(card.board_id, {:timeline_appended, card.id, entry})
    result
  end

  defp broadcast_appended({:error, _changeset} = result, _card), do: result

  defp split_actor(:agent), do: {:agent, nil}
  defp split_actor({:user, user_id}) when is_integer(user_id), do: {:user, user_id}

  defp preload_user({:ok, record}), do: {:ok, Repo.preload(record, :user)}
  defp preload_user({:error, changeset}), do: {:error, changeset}
end
