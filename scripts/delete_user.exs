defmodule UserAdmin do
  @moduledoc """
  Delete a user. Paste this whole file into `iex -S mix` (or a prod console:
  `fly ssh console -a relayboard`, then `/app/bin/relay remote`).

      UserAdmin.report("someone@example.com")                        # read-only, always run first
      UserAdmin.reassign_boards("someone@example.com", "you@x.com")  # if they own boards
      UserAdmin.delete("someone@example.com")                        # the actual delete

  Deleting a user cascades at the DB level. The dangerous one is `boards.owner_id`
  (`on_delete: :delete_all`) — deleting a board owner destroys the whole board:
  stages, cards, runs, comments, attachments, votes, flows, executors, api_keys.
  `delete/2` refuses to do that unless you pass `force: true`.

  Everything else is benign: the user's memberships, card ownerships, comments,
  activities, votes and tokens are deleted, while `cards.posted_by_user_id` and
  `api_keys.created_by_id` are nilified — those rows survive, just unattributed.
  """
  alias Relay.Repo
  alias Schemas.User

  # {table, column, effect}
  @cascades [
    {"board_members", "user_id", :deleted},
    {"card_owners", "user_id", :deleted},
    {"comments", "user_id", :deleted},
    {"activities", "user_id", :deleted},
    {"votes", "user_id", :deleted},
    {"device_tokens", "user_id", :deleted},
    {"user_api_tokens", "user_id", :deleted},
    {"cards", "posted_by_user_id", :nilified},
    {"api_keys", "created_by_id", :nilified}
  ]

  @doc "Dry run: show exactly what deleting this user would touch. Changes nothing."
  def report(email) do
    case Repo.get_by(User, email: email) do
      nil ->
        IO.puts("No user found with email #{inspect(email)}")
        :not_found

      user ->
        IO.puts("\n#{user.name} <#{user.email}>  (id=#{user.id}, #{user.provider})")

        boards = owned_boards(user.id)

        if boards == [] do
          IO.puts("\nOwns no boards — safe to delete.")
        else
          IO.puts("\n!! OWNS #{length(boards)} BOARD(S) — these would be DESTROYED with all their data:")

          for [id, name, cards] <- boards do
            IO.puts("     - #{name} (id=#{id}, #{cards} cards)")
          end

          IO.puts("   Reassign first:  UserAdmin.reassign_boards(#{inspect(email)}, \"new@owner.com\")")
        end

        IO.puts("\nTheir own rows:")

        for {table, col, effect} <- @cascades, n = count(table, col, user.id), n > 0 do
          IO.puts("     #{String.pad_trailing(table <> "." <> col, 32)} #{n} #{effect}")
        end

        IO.puts("")
        user
    end
  end

  @doc """
  Delete the user. Refuses if they own any board unless `force: true`.

      UserAdmin.delete("someone@example.com")
      UserAdmin.delete("someone@example.com", force: true)   # also destroys their boards
  """
  def delete(email, opts \\ []) do
    user = Repo.get_by(User, email: email)
    boards = user && owned_boards(user.id)

    cond do
      is_nil(user) ->
        IO.puts("No user found with email #{inspect(email)}")
        {:error, :not_found}

      boards != [] and not Keyword.get(opts, :force, false) ->
        IO.puts("""

        REFUSING — #{user.email} owns #{length(boards)} board(s).
        Deleting them would destroy those boards and every card, run, and comment on them.

          Safer:  UserAdmin.reassign_boards(#{inspect(email)}, "new@owner.com")
          Then:   UserAdmin.delete(#{inspect(email)})

          Or, if you really mean it:  UserAdmin.delete(#{inspect(email)}, force: true)
        """)

        {:error, :owns_boards}

      true ->
        {:ok, deleted} = Repo.delete(user)
        IO.puts("Deleted #{deleted.email} (id=#{deleted.id})")
        {:ok, deleted}
    end
  end

  @doc "Move every board owned by `from_email` to `to_email`. Do this before deleting."
  def reassign_boards(from_email, to_email) do
    from = Repo.get_by!(User, email: from_email)
    to = Repo.get_by!(User, email: to_email)

    %{num_rows: n} = Repo.query!("UPDATE boards SET owner_id = $1 WHERE owner_id = $2", [to.id, from.id])

    IO.puts("Moved #{n} board(s) from #{from.email} to #{to.email}")
    {:ok, n}
  end

  defp owned_boards(user_id) do
    Repo.query!(
      """
      SELECT b.id, b.name, (SELECT count(*) FROM cards c WHERE c.board_id = b.id)
      FROM boards b WHERE b.owner_id = $1 ORDER BY b.name
      """,
      [user_id]
    ).rows
  end

  defp count(table, col, user_id) do
    Repo.query!("SELECT count(*) FROM #{table} WHERE #{col} = $1", [user_id]).rows
    |> hd()
    |> hd()
  end
end
