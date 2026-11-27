defmodule Hamaca.Moderation do
  @moduledoc """
  Content moderation (RE510, Apple Guideline 1.2): reports, auto-hide, the operator's admin
  actions and Hamaca-wide suspension.

    * **Reports** — a signed-in user reports a public-board idea (`{:card, id}`) or another human
      member's comment (`{:comment, id}`) with `report/3`. The item is hidden for that reporter at
      once (`hidden_for_reporter_ids/2`) and for everyone once `auto_hide_threshold/0` distinct
      people have open reports on it. Every new report emails the operator
      (`Hamaca.Moderation.Notifier`).
    * **Admin actions** — `dismiss/2`, `hide/2` and `suspend/2` resolve every open report on an
      item as one batch (shared `resolved_at`); `undo/2` reverses a batch from any member report.
    * **Suspension is derived at read time** from `users.suspended_at`: a suspended user's ideas
      and comments read as hidden for everyone (`hidden_for_everyone?/1`,
      `exclude_hidden_cards/1`) and no rows are mass-updated, which is why Undo restores everything.

  The policy numbers live only here. This context reads `Schemas.*` directly and must not call
  `Hamaca.Boards` (Boards depends on it), nor `Hamaca.Billing`, nor the web layer.
  """

  use Boundary, deps: [Hamaca.Brand, Hamaca.Config, Hamaca.Mailer, Hamaca.Repo, Schemas]

  import Ecto.Query

  alias Ecto.Changeset
  alias Hamaca.Moderation.Notifier
  alias Hamaca.Repo
  alias Schemas.Card
  alias Schemas.Comment
  alias Schemas.ContentReport
  alias Schemas.Membership
  alias Schemas.Stage
  alias Schemas.User

  @type target :: {:card, integer()} | {:comment, integer()}
  @type row :: %{
          key: String.t(),
          kind: :card | :comment,
          target_id: integer(),
          board: Schemas.Board.t(),
          card_ref: String.t(),
          excerpt: String.t(),
          full_text: String.t(),
          poster: User.t() | nil,
          reporters: [User.t()],
          report_count: non_neg_integer(),
          notes: [%{reporter: User.t(), note: String.t()}],
          latest_reason: atom(),
          first_reported_at: DateTime.t(),
          due_at: DateTime.t(),
          status: :reporter_only | :auto_hidden | :admin_hidden,
          resolution: atom() | nil,
          resolved_by: User.t() | nil,
          resolved_at: DateTime.t() | nil,
          undo_report_id: integer() | nil
        }

  @auto_hide_threshold 2
  @response_sla_hours 24
  @due_soon_hours 6
  @resolved_limit 100
  @excerpt_length 140

  @report_preloads [
    :reporter,
    :resolved_by,
    card: [:board, :posted_by_user, :created_by_user],
    comment: [:user, card: :board]
  ]

  @doc "How many distinct people's open reports hide an item for everyone."
  @spec auto_hide_threshold() :: 2
  def auto_hide_threshold, do: @auto_hide_threshold

  @doc "How many hours the operator promises to respond to a report within."
  @spec response_sla_hours() :: 24
  def response_sla_hours, do: @response_sla_hours

  @doc "The admin row turns warning-styled when its deadline is within this many hours, or past."
  @spec due_soon_hours() :: 6
  def due_soon_hours, do: @due_soon_hours

  @doc "How many Resolved rows `list_resolved/0` returns."
  @spec resolved_limit() :: 100
  def resolved_limit, do: @resolved_limit

  # -- Reports ----------------------------------------------------------------------------------

  @doc """
  Records `user`'s report of `target`. `attrs` carries `reason` (an atom or its name as a string)
  and an optional `note`, under atom or string keys. A repeat report by the same person on the
  same item answers the existing report and changes nothing. Once `auto_hide_threshold/0`
  distinct people have open reports on an item that isn't already hidden, it is hidden for
  everyone (`:auto_reports`). A newly recorded report emails the operator after it commits.
  """
  @spec report(User.t(), target(), map()) ::
          {:ok, ContentReport.t()} | {:error, :own_content | :not_reportable | :suspended | Changeset.t()}
  def report(%User{} = user, target, attrs) when is_map(attrs) do
    with :ok <- check_not_suspended(user),
         :ok <- check_reportable(user, target) do
      user |> transact_report(target, attrs) |> after_report(target)
    end
  end

  defp transact_report(user, target, attrs), do: Repo.transaction(fn -> record_report(user, target, attrs) end)

  defp after_report({:ok, {:new, report}}, target), do: {:ok, notify_operator(report, target)}
  defp after_report({:ok, {:existing, report}}, _target), do: {:ok, report}
  defp after_report({:error, %Changeset{} = changeset}, _target), do: {:error, changeset}

  # After commit, so the email never announces a report that rolled back.
  defp notify_operator(report, target) do
    Notifier.dispatch(fn -> Notifier.deliver(Notifier.new_report_email(report, open_row!(target))) end)
    report
  end

  defp check_not_suspended(user), do: if(User.suspended?(user), do: {:error, :suspended}, else: :ok)

  defp check_reportable(%User{id: user_id}, target) do
    case target_facts(target, user_id) do
      nil -> {:error, :not_reportable}
      %{author_id: ^user_id} -> {:error, :own_content}
      %{reportable: true} -> :ok
      %{reportable: _} -> {:error, :not_reportable}
    end
  end

  # A card is reportable while it is live on a public board; a comment while it is a human's and
  # the reporter belongs to its board.
  defp target_facts({:card, id}, _user_id) do
    categories = Stage.public_categories()

    Repo.one(
      from c in Card,
        join: s in assoc(c, :stage),
        join: b in assoc(c, :board),
        where: c.id == ^id,
        select: %{
          author_id: c.posted_by_user_id,
          reportable: b.public_enabled and s.category in ^categories and is_nil(c.archived_at)
        }
    )
  end

  defp target_facts({:comment, id}, user_id) do
    member = from mb in Membership, where: mb.board_id == parent_as(:card).board_id and mb.user_id == ^user_id

    Repo.one(
      from m in Comment,
        join: c in assoc(m, :card),
        as: :card,
        join: b in assoc(c, :board),
        where: m.id == ^id,
        select: %{
          author_id: m.user_id,
          reportable:
            m.actor_type == :user and not is_nil(m.user_id) and
              (b.owner_id == ^user_id or exists(member))
        }
    )
  end

  # Runs inside the transaction. The target row is locked first, so a concurrent reporter waits
  # and then sees this report in both the repeat check and the auto-hide count.
  defp record_report(user, target, attrs) do
    locked = lock_target!(target)

    case Repo.one(from r in by_target(target), where: r.reporter_id == ^user.id) do
      %ContentReport{} = existing ->
        {:existing, existing}

      nil ->
        report =
          target
          |> new_report(user)
          |> ContentReport.changeset(report_params(attrs))
          |> Repo.insert()
          |> case do
            {:ok, report} -> report
            {:error, changeset} -> Repo.rollback(changeset)
          end

        maybe_auto_hide(locked, target)
        {:new, report}
    end
  end

  defp new_report({:card, id}, user), do: %ContentReport{reporter_id: user.id, card_id: id}
  defp new_report({:comment, id}, user), do: %ContentReport{reporter_id: user.id, comment_id: id}

  defp report_params(attrs) do
    for key <- [:reason, :note], value = param(attrs, key), not is_nil(value), into: %{}, do: {key, value}
  end

  defp param(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp maybe_auto_hide(%{hidden_at: nil} = item, target) do
    if Repo.aggregate(open_reports(target), :count) >= @auto_hide_threshold do
      set_hidden!(item, :auto_reports, now())
    end
  end

  defp maybe_auto_hide(_hidden_item, _target), do: :ok

  @doc """
  The ids of every card (`:card`) or comment (`:comment`) `user` ever reported, whatever its
  resolution — hidden for that person. `nil` (signed out) is the empty set.
  """
  @spec hidden_for_reporter_ids(User.t() | nil, :card | :comment) :: MapSet.t(integer())
  def hidden_for_reporter_ids(nil, _kind), do: MapSet.new()

  def hidden_for_reporter_ids(%User{id: user_id}, :card) do
    MapSet.new(
      Repo.all(from r in ContentReport, where: r.reporter_id == ^user_id and not is_nil(r.card_id), select: r.card_id)
    )
  end

  def hidden_for_reporter_ids(%User{id: user_id}, :comment) do
    MapSet.new(
      Repo.all(
        from r in ContentReport, where: r.reporter_id == ^user_id and not is_nil(r.comment_id), select: r.comment_id
      )
    )
  end

  @doc """
  True when the item is hidden for everyone: `hidden_at` is set, or its author is suspended. A
  card's `posted_by_user` (or a comment's `user`) must be preloaded; raises otherwise.
  """
  @spec hidden_for_everyone?(Card.t() | Comment.t()) :: boolean()
  def hidden_for_everyone?(%Card{hidden_at: hidden_at, posted_by_user: author}),
    do: hidden_or_suspended?(hidden_at, author)

  def hidden_for_everyone?(%Comment{hidden_at: hidden_at, user: author}), do: hidden_or_suspended?(hidden_at, author)

  defp hidden_or_suspended?(_hidden_at, %Ecto.Association.NotLoaded{}),
    do: raise(ArgumentError, "hidden_for_everyone?/1 needs the item's author preloaded")

  defp hidden_or_suspended?(hidden_at, author), do: not is_nil(hidden_at) or User.suspended?(author)

  @doc """
  Composes onto any `Schemas.Card` query (its root binding, whatever the caller named it): drops
  cards with `hidden_at` set and cards whose `posted_by_user` is suspended. Cards with no poster
  stay.
  """
  @spec exclude_hidden_cards(Ecto.Queryable.t()) :: Ecto.Query.t()
  def exclude_hidden_cards(query) do
    from [c] in query,
      left_join: poster in User,
      on: poster.id == c.posted_by_user_id,
      where: is_nil(c.hidden_at) and is_nil(poster.suspended_at)
  end

  @doc "`text` trimmed and cut to at most 140 characters, ending in `…` when cut; nil reads as `\"\"`."
  @spec excerpt(String.t() | nil) :: String.t()
  def excerpt(nil), do: ""

  def excerpt(text) when is_binary(text) do
    trimmed = String.trim(text)

    if String.length(trimmed) > @excerpt_length do
      String.trim_trailing(String.slice(trimmed, 0, @excerpt_length - 1)) <> "…"
    else
      trimmed
    end
  end

  # -- The admin queue --------------------------------------------------------------------------

  @doc "One row per item with open reports, the longest-waiting first."
  @spec list_open() :: [row()]
  def list_open do
    from(r in ContentReport, where: is_nil(r.resolved_at))
    |> load_reports()
    |> Enum.group_by(&target_of/1)
    |> Enum.map(fn {_target, reports} -> build_row(reports) end)
    |> Enum.sort_by(&{DateTime.to_unix(&1.first_reported_at), &1.target_id})
  end

  @doc """
  One row per resolved batch (target + action + `resolved_at`), newest first, at most
  `resolved_limit/0`.
  """
  @spec list_resolved() :: [row()]
  def list_resolved do
    batches =
      Repo.all(
        from r in ContentReport,
          where: not is_nil(r.resolved_at),
          group_by: [r.card_id, r.comment_id, r.resolved_at, r.resolution],
          order_by: [desc: r.resolved_at, desc: max(r.id)],
          limit: @resolved_limit,
          select: {r.card_id, r.comment_id, r.resolved_at, r.resolution}
      )

    case batches do
      [] ->
        []

      batches ->
        oldest = batches |> Enum.map(&elem(&1, 2)) |> Enum.min(DateTime)

        grouped =
          from(r in ContentReport, where: r.resolved_at >= ^oldest)
          |> load_reports()
          |> Enum.group_by(&{&1.card_id, &1.comment_id, &1.resolved_at, &1.resolution})

        Enum.map(batches, &build_row(Map.fetch!(grouped, &1)))
    end
  end

  @doc "How many items have open reports (the number of `list_open/0` rows)."
  @spec open_count() :: non_neg_integer()
  def open_count do
    from(r in ContentReport,
      where: is_nil(r.resolved_at),
      group_by: [r.card_id, r.comment_id],
      select: %{card_id: r.card_id}
    )
    |> subquery()
    |> Repo.aggregate(:count)
  end

  @doc """
  Resolves `target`'s open reports as `:dismissed` and clears an auto-hide (`:auto_reports`) on
  it. Any other hide (`:admin`) stays. Answers how many it resolved.
  """
  @spec dismiss(User.t(), target()) :: {:ok, non_neg_integer()} | {:error, :no_open_reports}
  def dismiss(%User{} = admin, target) do
    resolve(admin, target, :dismissed, fn item, _now ->
      if item.hidden_reason == :auto_reports, do: set_unhidden!(item)
      {:ok, nil}
    end)
  end

  @doc "Resolves `target`'s open reports as `:hidden` and hides it for everyone (`:admin`)."
  @spec hide(User.t(), target()) :: {:ok, non_neg_integer()} | {:error, :no_open_reports}
  def hide(%User{} = admin, target) do
    resolve(admin, target, :hidden, fn item, now ->
      set_hidden!(item, :admin, now)
      {:ok, nil}
    end)
  end

  @doc """
  Suspends `target`'s poster (a card's `posted_by_user`, else its `created_by_user`; a comment's
  `user`), hides the item (`:admin`) and resolves its open reports as `:suspended`. A poster who
  is already suspended stays as they are, and the batch records no `suspended_user_id`, so Undo
  leaves them suspended. Answers the reloaded poster.
  """
  @spec suspend(User.t(), target()) ::
          {:ok, User.t()} | {:error, :no_open_reports | :no_poster | :cannot_suspend_superadmin}
  def suspend(%User{} = admin, target) do
    case resolve(admin, target, :suspended, &suspend_poster(&1, admin, &2)) do
      {:ok, %{poster_id: poster_id}} -> {:ok, Repo.get!(User, poster_id)}
      error -> error
    end
  end

  defp suspend_poster(item, admin, now) do
    with {:ok, poster} <- poster_of(item),
         :ok <- check_suspendable(poster) do
      suspended_id = if User.suspended?(poster), do: nil, else: suspend_user!(poster, admin, now).id
      set_hidden!(item, :admin, now)
      {:ok, %{poster_id: poster.id, suspended_user_id: suspended_id}}
    end
  end

  # Locks the target, checks it has open reports, runs `act` (which may refuse), then stamps
  # every open report with the one batch `resolved_at`. Answers the resolved count, or what
  # `act` handed back for `suspend/2`.
  defp resolve(admin, target, resolution, act) do
    Repo.transaction(fn ->
      item = lock_target!(target)
      now = now()
      open = open_reports(target)

      if Repo.aggregate(open, :count) == 0, do: Repo.rollback(:no_open_reports)

      case act.(item, now) do
        {:ok, extra} ->
          {count, _} =
            Repo.update_all(open,
              set: [
                resolution: resolution,
                resolved_by_id: admin.id,
                resolved_at: now,
                prior_hidden_reason: item.hidden_reason,
                suspended_user_id: extra && extra.suspended_user_id,
                updated_at: now
              ]
            )

          extra || count

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp poster_of(%Card{posted_by_user_id: nil, created_by_user_id: nil}), do: {:error, :no_poster}
  defp poster_of(%Card{posted_by_user_id: nil, created_by_user_id: id}), do: {:ok, Repo.get!(User, id)}
  defp poster_of(%Card{posted_by_user_id: id}), do: {:ok, Repo.get!(User, id)}
  defp poster_of(%Comment{user_id: nil}), do: {:error, :no_poster}
  defp poster_of(%Comment{user_id: id}), do: {:ok, Repo.get!(User, id)}

  defp check_suspendable(%User{email: email}) do
    if email in Schemas.Scope.superadmin_emails(), do: {:error, :cannot_suspend_superadmin}, else: :ok
  end

  defp suspend_user!(user, admin, now) do
    user |> Changeset.change(suspended_at: now, suspended_by_id: admin.id) |> Repo.update!()
  end

  @doc """
  Reverses the batch `report_id` belongs to: a Hide or Suspend puts the item's hidden state back
  to what it was just before (`prior_hidden_reason`); a Dismiss restores the auto-hide it cleared,
  if it cleared one and the item is not hidden again since, and otherwise leaves the item as it
  is. A suspension that batch made is lifted, and its reports are open again.
  """
  @spec undo(User.t(), integer()) :: :ok | {:error, :not_found | :not_resolved}
  def undo(%User{} = _admin, report_id) when is_integer(report_id) do
    case Repo.get(ContentReport, report_id) do
      nil -> {:error, :not_found}
      %ContentReport{resolved_at: nil} -> {:error, :not_resolved}
      %ContentReport{} = report -> reverse_batch(report)
    end
  end

  defp reverse_batch(%ContentReport{} = report) do
    target = target_of(report)

    Repo.transaction(fn ->
      item = lock_target!(target)

      batch =
        from r in by_target(target), where: r.resolved_at == ^report.resolved_at and r.resolution == ^report.resolution

      batch
      |> select([r], r.suspended_user_id)
      |> where([r], not is_nil(r.suspended_user_id))
      |> distinct(true)
      |> Repo.all()
      |> Enum.each(&lift_suspension!/1)

      restore_hidden!(item, report)

      Repo.update_all(batch,
        set: [
          resolution: nil,
          resolved_by_id: nil,
          resolved_at: nil,
          prior_hidden_reason: nil,
          suspended_user_id: nil,
          updated_at: now()
        ]
      )
    end)

    :ok
  end

  # Dismiss only ever cleared an auto-hide, so its Undo only ever restores one — and never over a
  # hide made since. Hide and Suspend put back exactly the state they replaced.
  defp restore_hidden!(item, %ContentReport{resolution: :dismissed, prior_hidden_reason: :auto_reports}) do
    if is_nil(item.hidden_at), do: set_hidden!(item, :auto_reports, now())
  end

  defp restore_hidden!(_item, %ContentReport{resolution: :dismissed}), do: :ok
  defp restore_hidden!(item, %ContentReport{prior_hidden_reason: nil}), do: set_unhidden!(item)

  defp restore_hidden!(item, %ContentReport{prior_hidden_reason: prior}),
    do: set_hidden!(item, prior, item.hidden_at || now())

  defp lift_suspension!(user_id) do
    Repo.update_all(from(u in User, where: u.id == ^user_id), set: [suspended_at: nil, suspended_by_id: nil])
  end

  # -- Rows -------------------------------------------------------------------------------------

  # The open row for one target — the operator email's content.
  defp open_row!(target) do
    from(r in by_target(target), where: is_nil(r.resolved_at))
    |> load_reports()
    |> build_row()
  end

  defp load_reports(query) do
    Repo.all(from r in query, order_by: [asc: r.inserted_at, asc: r.id], preload: ^@report_preloads)
  end

  defp build_row([first | _] = reports) do
    last = List.last(reports)
    {kind, target_id} = target_of(first)
    item = item_of(first)
    board = board_of(first)
    full_text = full_text(item)

    %{
      key: row_key(kind, target_id, first.resolved_at),
      kind: kind,
      target_id: target_id,
      board: board,
      card_ref: Card.ref(board, card_of(first)),
      excerpt: excerpt(full_text),
      full_text: full_text,
      poster: poster(item),
      reporters: Enum.map(reports, & &1.reporter),
      report_count: length(reports),
      notes: for(r <- reports, r.note, do: %{reporter: r.reporter, note: r.note}),
      latest_reason: last.reason,
      first_reported_at: first.inserted_at,
      due_at: DateTime.add(first.inserted_at, @response_sla_hours * 3600),
      status: status(item.hidden_reason),
      resolution: first.resolution,
      resolved_by: first.resolved_at && first.resolved_by,
      resolved_at: first.resolved_at,
      undo_report_id: first.resolved_at && first.id
    }
  end

  defp row_key(kind, id, nil), do: "#{kind}-#{id}"
  defp row_key(kind, id, resolved_at), do: "#{kind}-#{id}-#{DateTime.to_unix(resolved_at)}"

  defp item_of(%ContentReport{card: %Card{} = card}), do: card
  defp item_of(%ContentReport{comment: %Comment{} = comment}), do: comment

  defp card_of(%ContentReport{card: %Card{} = card}), do: card
  defp card_of(%ContentReport{comment: %Comment{card: card}}), do: card

  defp board_of(report), do: card_of(report).board

  defp full_text(%Card{title: title, public_description: description}) do
    case description && String.trim(description) do
      blank when blank in [nil, ""] -> title
      description -> "#{title} — #{description}"
    end
  end

  defp full_text(%Comment{body: body}), do: body

  defp poster(%Card{posted_by_user: poster, created_by_user: creator}), do: poster || creator
  defp poster(%Comment{user: user}), do: user

  defp status(nil), do: :reporter_only
  defp status(:auto_reports), do: :auto_hidden
  defp status(:admin), do: :admin_hidden

  # -- Targets ----------------------------------------------------------------------------------

  defp target_of(%ContentReport{card_id: nil, comment_id: id}), do: {:comment, id}
  defp target_of(%ContentReport{card_id: id}), do: {:card, id}

  defp by_target({:card, id}), do: from(r in ContentReport, where: r.card_id == ^id)
  defp by_target({:comment, id}), do: from(r in ContentReport, where: r.comment_id == ^id)

  defp open_reports(target), do: from(r in by_target(target), where: is_nil(r.resolved_at))

  defp lock_target!({:card, id}), do: Repo.one!(from c in Card, where: c.id == ^id, lock: "FOR UPDATE")
  defp lock_target!({:comment, id}), do: Repo.one!(from m in Comment, where: m.id == ^id, lock: "FOR UPDATE")

  defp set_hidden!(item, reason, at), do: item |> Changeset.change(hidden_at: at, hidden_reason: reason) |> Repo.update!()
  defp set_unhidden!(item), do: item |> Changeset.change(hidden_at: nil, hidden_reason: nil) |> Repo.update!()

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
