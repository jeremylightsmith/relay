defmodule Relay.Presence do
  @moduledoc """
  Who is looking at a board's story map right now, and where their pointer is (RE257) — the
  app's first `Phoenix.Presence` context.

  Two board-scoped topics, both owned here:

    * `"story_map_presence:<board_id>"` — the roster, via Phoenix.Presence's own diff protocol
      (`%Phoenix.Socket.Broadcast{event: "presence_diff"}`).
    * `"story_map_cursor:<board_id>"` — the ephemeral cursor stream,
      `{:story_map_cursor, user_id, name, email, x, y}` and
      `{:story_map_cursor_gone, user_id}`.

  **Why neither goes through `Relay.Events`.** `Events.broadcast/2` calls
  `Relay.BoardWatch.bump/1` on *every* call, so routing cursor moves through it would advance
  the board version ~20 times a second per user and make the CLI refetch the whole board on
  every mouse twitch — the same write storm the batched `:card_log_appended` event exists to
  avoid. Presence and cursors are not domain mutations and must never bump the board version.
  `Relay.PresenceTest` pins that.

  **Only people viewing the story map are tracked** (interview decision 3): `RelayWeb.BoardLive`
  calls `track_viewer/3` from mount only for `live_action == :story_map`, and the kanban board
  neither tracks nor subscribes. Untracking needs no code — Presence untracks on the tracked
  pid's exit, and the Board ↔ Story map switch is a `<.link navigate>`, which shuts the
  LiveView down.

  **Humans only** (decision 2): there is no AI/agent avatar and no agent cursor. Agent activity
  stays visible through the existing card owner avatars and the run panel.

  **Naming.** `use Phoenix.Presence` already injects `track/3` and `list/1`, so this module's
  public roster API is `track_viewer/3` and `list_people/1` rather than the shorter names —
  a second clause at the same arity would be a compile warning, and this suite treats warnings
  as errors.
  """

  # `use Phoenix.Presence` must come BEFORE `use Boundary`: both macros stash their opts in the
  # same `@opts` module attribute, and `Boundary.Definition`'s `@before_compile` reads whatever
  # `@opts` holds at the END of the module body. Boundary second means its own opts (`deps:
  # [Schemas]`) are what survive; Phoenix.Presence second would leave Boundary reading
  # `otp_app`/`pubsub_server` as bogus boundary options (a real "unknown option" warning, fatal
  # under this suite's `--warnings-as-errors`). Phoenix.Presence's own use of `@opts` is safe
  # either way: it is read inside `child_spec/1`, which is compiled (and its `@opts` value
  # captured) at the point `use Phoenix.Presence` expands, not at the end of the module.
  use Phoenix.Presence, otp_app: :relay, pubsub_server: Relay.PubSub
  use Boundary, deps: [Schemas]

  alias Schemas.User

  @pubsub Relay.PubSub

  @doc """
  Tracks `pid` as a viewer of `board_id`'s story map.

  Keyed by the **user id**, so one person with three tabs is one roster entry and one avatar;
  `joined_at` breaks the roster's sort ties and is taken from the person's earliest live tab.
  """
  def track_viewer(pid, board_id, %User{} = user) do
    track(pid, presence_topic(board_id), to_string(user.id), %{
      name: user.name,
      email: user.email,
      avatar_url: user.avatar_url,
      joined_at: System.system_time(:millisecond)
    })
  end

  @doc "Subscribes the calling process to `board_id`'s roster AND cursor topics."
  def subscribe(board_id) do
    :ok = Phoenix.PubSub.subscribe(@pubsub, presence_topic(board_id))
    :ok = Phoenix.PubSub.subscribe(@pubsub, cursor_topic(board_id))
  end

  @doc """
  The roster for `board_id`: one entry per **person** regardless of tab count, sorted by
  `joined_at` then `user_id` so every viewer renders the stack in the same order.
  """
  def list_people(board_id) do
    board_id
    |> presence_topic()
    |> list()
    |> Enum.map(fn {user_id, %{metas: metas}} ->
      meta = Enum.min_by(metas, & &1.joined_at)

      {String.to_integer(user_id), meta}
    end)
    |> Enum.sort_by(fn {user_id, meta} -> {meta.joined_at, user_id} end)
    |> Enum.map(fn {user_id, meta} ->
      %{user_id: user_id, name: meta.name, email: meta.email, avatar_url: meta.avatar_url}
    end)
  end

  @doc """
  Relays one cursor position. `x`/`y` are raw pixels in the map's scrollable **content** space
  (see `assets/js/hooks/story_map_cursors.js`).

  `email` travels in the message because the receiver derives the person's identity colour from
  it (`RelayWeb.CoreComponents.identity_color/1`) — reading it off the roster instead would race
  the presence diff, which Phoenix computes in an async task.
  """
  def broadcast_cursor(board_id, %User{} = user, x, y) when is_integer(x) and is_integer(y) do
    fire(board_id, {:story_map_cursor, user.id, user.name, user.email, x, y})
  end

  @doc "Tells every viewer to drop `user_id`'s cursor."
  def broadcast_cursor_gone(board_id, user_id) when is_integer(user_id) do
    fire(board_id, {:story_map_cursor_gone, user_id})
  end

  @doc "The roster topic for `board_id`."
  def presence_topic(board_id), do: "story_map_presence:#{board_id}"

  @doc "The cursor topic for `board_id`."
  def cursor_topic(board_id), do: "story_map_cursor:#{board_id}"

  # Fire-and-forget, mirroring Relay.Events.broadcast/2: a PubSub failure can never fail the
  # interaction that triggered it, and a dropped cursor frame is invisible at 20 Hz.
  defp fire(board_id, message) do
    _ = Phoenix.PubSub.broadcast(@pubsub, cursor_topic(board_id), message)
    :ok
  end
end
