defmodule Relay.Push do
  @moduledoc """
  Push notifications (RLY-81, brief §06): the reason Relay is on the phone.

  Owns registered devices (`Schemas.DeviceToken`), the recipient fan-out, the
  APNs payload, the app-icon badge count, and the delivery adapter seam
  (`Relay.Push.Delivery`).

  **Depends on `Relay.Members`/`Relay.Repo`, never on `Relay.Cards`** — `Cards`
  calls `Push` from `set_status/3`, so a back-dependency would be a boundary
  cycle. That is also why the card ref is formatted here rather than reusing
  `Cards.ref/2`.
  """

  use Boundary, deps: [Relay.Members, Relay.Repo, Schemas]

  import Ecto.Query

  alias Relay.Members
  alias Relay.Repo
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.DeviceToken
  alias Schemas.Membership
  alias Schemas.User

  require Logger

  @doc """
  Registers `token` as a push device for `user`, upserting on the token: a
  device that re-registers (including after an account switch) re-points to
  `user` and re-stamps `last_registered_at` rather than duplicating.
  """
  def register_device(user, token, platform \\ :ios)

  def register_device(%User{} = user, token, platform) when is_binary(token) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    %DeviceToken{user_id: user.id}
    |> DeviceToken.changeset(%{token: token, platform: platform, last_registered_at: now})
    |> Repo.insert(
      conflict_target: :token,
      on_conflict: [set: [user_id: user.id, platform: platform, last_registered_at: now, updated_at: now]]
    )
  end

  @doc """
  Removes `user`'s registration of `token` (sign-out cleanup). Idempotent, and
  scoped to `user` so one account can never unregister another's device.
  """
  def unregister_device(%User{id: user_id}, token) when is_binary(token) do
    Repo.delete_all(from d in DeviceToken, where: d.user_id == ^user_id and d.token == ^token)
    :ok
  end

  @doc """
  Deletes `token`'s registration regardless of owner. For delivery adapters
  pruning a device Apple reported as gone (410 Unregistered / 400
  BadDeviceToken), where there is no user in hand. Idempotent.
  """
  def delete_device_token(token) when is_binary(token) do
    Repo.delete_all(from d in DeviceToken, where: d.token == ^token)
    :ok
  end

  @doc """
  How many cards need `user`: unarchived cards in `:needs_input` or `:in_review`
  on any non-archived board `user` is a resolved member of, across boards.
  Stamped onto every push as `aps.badge`.

  **Must agree with `Cards.needs_you_feed/1`.** That function is the documented
  single source of truth for this two-status set (ADR 0005) — the F4 feed, the
  F5 badge (this function, RLY-81), and the inbox (RLY-85) all have to return
  the same cards. `Push` cannot call `Cards` (that would be a Boundary cycle:
  `Cards.set_status/3` calls `Push`), so this mirrors `Cards.needs_you_feed/1`'s
  scoping by hand instead of sharing it. Keep the two in sync by hand too.
  """
  def needs_you_count(%User{id: user_id}) do
    Repo.aggregate(
      from(c in Card,
        join: m in Membership,
        on: m.board_id == c.board_id,
        join: b in Board,
        on: b.id == c.board_id,
        where: m.user_id == ^user_id,
        where: c.status in [:needs_input, :in_review],
        where: is_nil(c.archived_at),
        where: is_nil(b.archived_at)
      ),
      :count
    )
  end

  @doc """
  The push trigger: `card` just **entered** `from_status → card.status`, performed
  by `actor`. Notifies every resolved human member of the card's board except the
  actor, one push per registered device, each stamped with that recipient's own
  `needs_you_count/1` as the badge.

  **Fire-and-forget.** Always returns `:ok` immediately and never raises into the
  caller: the recipient query and the network call run under
  `Relay.Push.TaskSupervisor` (inline when `config :relay, Relay.Push, async: false`,
  as in `:test`), and any error is logged and swallowed. A push failure can never
  fail the status change that triggered it — the same contract as
  `Relay.Events.broadcast/2`.

  `from_status` is part of the contract but unused: the *edge* guard (only fire
  when `card.status` actually changed) lives at the call site
  (`Relay.Cards.set_status/3`), which is the only place that sees it. Which
  statuses are push-worthy is decided here, by this clause's guard — the one
  and only place that list lives, so `Cards` never has to know it.
  """
  def card_status_changed(card, from_status, actor)

  def card_status_changed(%Card{status: status} = card, _from_status, actor) when status in [:needs_input, :in_review] do
    dispatch(fn -> notify(card, actor) end)
    :ok
  end

  def card_status_changed(%Card{}, _from_status, _actor), do: :ok

  # The whole dispatch decision — including the `start_child` call itself — runs
  # under `safely/1`. `start_child` is a `GenServer.call` to the named
  # supervisor: if that process is ever unavailable (crashed and mid-restart, a
  # rename drifted out of sync with `Relay.Application`) it *exits* rather than
  # returning an error tuple, and an unprotected exit here would propagate
  # straight into the caller of `set_status/3`.
  defp dispatch(fun) do
    safely(fn -> dispatch_now(fun) end)
    :ok
  end

  defp dispatch_now(fun) do
    if async?() do
      Task.Supervisor.start_child(Relay.Push.TaskSupervisor, fn -> safely(fun) end)
    else
      fun.()
    end
  end

  defp async? do
    :relay
    |> Application.get_env(Relay.Push, [])
    |> Keyword.get(:async, true)
  end

  defp safely(fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.error("[push] dispatch failed: #{Exception.format(:error, error, __STACKTRACE__)}")
      :ok
  catch
    kind, reason ->
      Logger.error("[push] dispatch #{kind}: #{inspect(reason)}")
      :ok
  end

  defp notify(%Card{} = card, actor) do
    board = Repo.get!(Board, card.board_id)
    adapter = adapter()

    for user <- recipients(board, actor), tokens = device_tokens(user), tokens != [] do
      payload = payload(card, board, needs_you_count(user))

      for token <- tokens do
        adapter.deliver(token, payload)
      end
    end

    :ok
  end

  # Every resolved human member of the board, minus the acting user. Ownership is
  # provenance (and is often the AI), so there is no per-card human assignee to
  # narrow to — the board's Members roster is the recipient set (ADR 0005, matching
  # F4's board-level "needs you"). `:agent` excludes nobody.
  defp recipients(%Board{} = board, actor) do
    actor_user_id =
      case actor do
        {:user, id} -> id
        _other -> nil
      end

    board
    |> Members.list_members()
    |> Enum.reject(&Membership.invited?/1)
    |> Enum.map(& &1.user)
    |> Enum.reject(&(&1.id == actor_user_id))
    |> Enum.uniq_by(& &1.id)
  end

  defp device_tokens(%User{id: user_id}) do
    Repo.all(from d in DeviceToken, where: d.user_id == ^user_id, select: d.token)
  end

  # The APNs payload (RLY-81 spec §5). `card_ref` + `board_slug` are the deep-link
  # keys the app routes on: the web opens a card at /board/:slug?card=:ref.
  defp payload(%Card{} = card, %Board{} = board, badge) do
    {title, kind} = copy(card.status)
    ref = ref(board, card)

    %{
      "aps" => %{
        "alert" => %{"title" => title, "body" => "#{ref}: #{card.title}"},
        "badge" => badge,
        "sound" => "default"
      },
      "card_ref" => ref,
      "board_slug" => board.slug,
      "kind" => kind
    }
  end

  # V1 copy, kept in one place so it is trivial to tune.
  defp copy(:needs_input), do: {"Question from the AI", "needs_input"}
  defp copy(:in_review), do: {"Ready for your review", "in_review"}

  # Duplicates `Relay.Cards.ref/2` on purpose: `Push` cannot depend on `Cards`
  # (Cards calls Push — a back-dep would be a boundary cycle).
  defp ref(%Board{key: key}, %Card{ref_number: ref_number}), do: "#{key}-#{ref_number}"

  @doc "The configured delivery adapter (see `Relay.Push.Delivery`)."
  def adapter do
    :relay
    |> Application.get_env(Relay.Push, [])
    |> Keyword.get(:adapter, Relay.Push.Delivery.Log)
  end
end
