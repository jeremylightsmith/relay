defmodule Relay.Activity do
  @moduledoc """
  The Activity context: a card's conversational and audit record —
  comments posted by humans or the AI, and activity entries logged for
  every meaningful card change (MMF 07).

  An "actor" is either the single Relay AI agent (`:agent`) or a user
  (`{:user, user_id}`) — the same concept `Relay.Cards` uses for owners.
  This context never calls `Relay.Cards`; `Cards` depends on it to log.
  """

  use Boundary, deps: [Relay.Events, Relay.Repo, Schemas], exports: [LogSink, Pruner]

  import Ecto.Query

  alias Relay.Events
  alias Relay.Repo
  alias Schemas.Attachment
  alias Schemas.Card
  alias Schemas.Comment

  @images_not_on_card "must be images uploaded to this card"

  @doc """
  Posts a comment on `card` from `attrs` — `:actor`
  (`:agent | {:user, user_id}`, programmatic), `:body` (the only
  user-supplied text), an optional `:kind`
  (`:comment | :question | :changes_requested`, programmatic, defaults to
  `:comment`), and (RE427) optional `:image_ids` — ids of image attachments
  already uploaded to this card and not yet on a note, linked to the comment in
  the given order (defaults to `[]`; with at least one the body may be blank).

  Returns `{:ok, comment}` with the author and `:images` (position order, `[]`
  when none) preloaded, or `{:error, changeset}`. Too many images
  (`Schemas.Comment.max_images/0`) or any id that is not an unlinked image on
  this card is an error on `:images`, and nothing is persisted. The comment is
  broadcast only once it and its image links are committed.
  """
  def add_comment(%Card{} = card, %{actor: actor} = attrs) do
    {actor_type, user_id} = split_actor(actor)
    image_ids = attrs |> Map.get(:image_ids, []) |> Enum.uniq()

    changeset =
      Comment.changeset(
        %Comment{card_id: card.id, actor_type: actor_type, user_id: user_id, kind: Map.get(attrs, :kind, :comment)},
        Map.take(attrs, [:body]),
        length(image_ids)
      )

    changeset
    |> insert_with_images(card, image_ids)
    |> broadcast_appended(card)
  end

  # Validated before the transaction so an invalid comment never rolls back a caller's
  # surrounding transaction; only a failed image link (which needs the inserted id) does.
  defp insert_with_images(%Ecto.Changeset{valid?: false} = changeset, _card, _image_ids),
    do: {:error, %{changeset | action: :insert}}

  defp insert_with_images(changeset, card, image_ids) do
    Repo.transaction(fn ->
      with {:ok, comment} <- Repo.insert(changeset),
           :ok <- link_images(comment, card, image_ids) do
        Repo.preload(comment, [:user, :images])
      else
        {:error, %Ecto.Changeset{} = failed} -> Repo.rollback(failed)
        :error -> Repo.rollback(Ecto.Changeset.add_error(changeset, :images, @images_not_on_card))
      end
    end)
  end

  defp link_images(_comment, _card, []), do: :ok

  # One guarded update: only this card's unlinked images match, so a foreign, non-image,
  # already-linked or unknown id leaves the count short and the caller rolls back. `position`
  # is each id's index in the posted list.
  defp link_images(comment, card, image_ids) do
    with {:ok, uuids} <- cast_uuids(image_ids) do
      {linked, _} =
        Repo.update_all(
          from(a in Attachment,
            where:
              a.id in ^uuids and a.card_id == ^card.id and is_nil(a.comment_id) and
                a.content_type in ^Attachment.image_types(),
            update: [
              set: [
                comment_id: ^comment.id,
                position: fragment("array_position(?, ?) - 1", type(^uuids, {:array, Ecto.UUID}), a.id)
              ]
            ]
          ),
          []
        )

      if linked == length(uuids), do: :ok, else: :error
    end
  end

  defp cast_uuids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> {:cont, {:ok, acc ++ [uuid]}}
        :error -> {:halt, :error}
      end
    end)
  end

  @doc """
  Appends an activity entry to `card`'s log from `attrs` — `:type`
  (`:created | :moved | :status_changed | :owners_changed | :commented | :approved | :rejected | :needs_input | :input_answered`),
  `:actor` (`:agent | {:user, user_id}`), optional `:meta` (a map
  with STRING keys and primitive values, stored as jsonb; defaults to
  `%{}`), and optional `:text` (the rendered line for `:action` rows —
  RLY-148's Retry writes `"retry requested"`; defaults to nil) — returning
  `{:ok, activity}` with the actor preloaded or `{:error, changeset}`.
  """
  def log(%Card{} = card, %{type: type, actor: actor} = attrs) do
    {actor_type, user_id} = split_actor(actor)

    %Schemas.Activity{
      card_id: card.id,
      type: type,
      meta: Map.get(attrs, :meta, %{}),
      text: Map.get(attrs, :text),
      actor_type: actor_type,
      user_id: user_id
    }
    |> Schemas.Activity.changeset()
    |> Repo.insert()
    |> preload_user()
    |> broadcast_appended(card)
  end

  @doc """
  The design's entry `kind` (`:action | :failure | :move | :decision`), derived
  from the stored `type` at render — never stored, so every pre-RLY-112 row
  classifies itself with no backfill (RLY-112, artboard §03).

  The catch-all maps the legacy audit types (`:created`, `:status_changed`,
  `:owners_changed`, `:archived`, `:unarchived`, `:commented`) to `:action`, which
  keeps today's entries rendering exactly as they do now.

  **Never prune by `kind`** — it lumps those audit rows in with runner chatter.
  `Relay.Activity.Pruner` matches `type == :action`, which is exactly the runner lines.
  """
  def kind(%Schemas.Activity{type: :action}), do: :action
  def kind(%Schemas.Activity{type: :failure}), do: :failure
  def kind(%Schemas.Activity{type: :moved}), do: :move

  def kind(%Schemas.Activity{type: type}) when type in [:approved, :rejected, :needs_input, :input_answered],
    do: :decision

  def kind(%Schemas.Activity{}), do: :action

  @doc """
  The card's full timeline: its comments and activity entries merged
  into one list, ascending by `inserted_at` (comments sort before
  activity entries logged in the same second; within a source, ties
  break by id), each entry with its `:user` preloaded (`nil` for the
  agent) and each comment with its `:images` (RE427, position order).
  """
  def list_timeline(%Card{id: card_id}) do
    comments =
      Repo.all(
        from c in Comment,
          where: c.card_id == ^card_id,
          order_by: [asc: c.inserted_at, asc: c.id],
          preload: [:user, :images]
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
  (`nil` for the agent) and its `:images` (RE427, position order).
  """
  def list_conversation(%Card{id: card_id}) do
    Repo.all(
      from c in Comment,
        where: c.card_id == ^card_id,
        order_by: [asc: c.inserted_at, asc: c.id],
        preload: [:user, :images]
    )
  end

  @doc """
  The card's activity log: its activity entries only, descending by `inserted_at`
  (ties break by id), so the newest sits at the top. Each entry has its `:user`
  preloaded (`nil` for the agent).

  `opts[:limit]` caps the rows returned (RLY-112: the drawer renders the newest
  200 — without a cap a card mid-run would try to paint thousands of `:action`
  rows). This is a *render* cap, distinct from `Relay.Activity.Pruner`'s
  *storage* retention.
  """
  def list_activity(%Card{id: card_id}, opts \\ []) do
    Schemas.Activity
    |> where([a], a.card_id == ^card_id)
    |> order_by([a], desc: a.inserted_at, desc: a.id)
    |> maybe_limit(Keyword.get(opts, :limit))
    |> preload(:user)
    |> Repo.all()
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit) when is_integer(limit) and limit > 0, do: limit(query, ^limit)

  @doc """
  The newest activity entry for each of `card_ids`, as `%{card_id => entry}` —
  one `DISTINCT ON` query, so a board renders its whole health column without an
  N+1 (RLY-112). Cards with no entries are simply absent. `:user` is NOT
  preloaded: the only caller derives health and strip text, neither of which
  reads the actor.
  """
  def newest_per_card(card_ids) when is_list(card_ids) do
    from(a in Schemas.Activity,
      where: a.card_id in ^card_ids,
      distinct: [a.card_id],
      order_by: [asc: a.card_id, desc: a.inserted_at, desc: a.id]
    )
    |> Repo.all()
    |> Map.new(&{&1.card_id, &1})
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
