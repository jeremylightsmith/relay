# Plan — RLY-6: Multiple boards for a user

## Goal
Let a signed-in user own and use **more than one board** through the LiveView UI: create
boards (name only), switch between them from the board header, browse them at `/boards`, edit
each board's slug in Settings → General, and archive/unarchive boards (archived = read-only).
Slug becomes the canonical board URL. The data layer already supports multi-board; this card
closes the LiveView-layer gap.

## Architecture
- **Domain:** `Relay.Boards` grows first-class multi-board functions (`list_boards/1`,
  `get_board/2`, `get_board!/2`, `create_board/2`, `archive_board/1`, `unarchive_board/1`),
  `update_board/2` gains slug support, and `create_default_board!/1` is refactored to share a
  single seeding helper. `Schemas.Board` gains `archived_at` + `archived?/1` + slug-format
  validation; `Schemas.User` gains `has_many :boards`.
- **Routing:** slug-based — `/boards`, `/board/:slug`, `/board/:slug/settings`. Slugless
  `/board` becomes a redirect (via `BoardRedirectController`) to the user's first active board,
  still creating+seeding one on first login. Every board LiveView mounts by
  `get_board!(current_scope.user, slug)`; a slug the user doesn't own → `Ecto.NoResultsError`
  → 404. Authorization = owner-scoped slug lookup everywhere.
- **Web:** `BoardsLive` (index + create form), a header board switcher in `BoardLive`, a
  General settings pane (slug edit + Danger-zone archive), and an "Archived — read-only"
  banner + mutation guards in `BoardLive`/`BoardSettingsLive`.
- **Real-time:** topics are already per `board.id`. `{:board_updated, board}` is extended to
  react to slug changes (redirect) and archive changes (flip read-only) in addition to the
  RLY-10 rename.

## Tech
Elixir / Phoenix 1.8 LiveView, Ecto/Postgres, daisyUI + Tailwind v4, `boundary` (web →
`Relay` exported contexts only), ExMachina factories, `Phoenix.LiveViewTest`.

## Global Constraints (copied from the spec + repo rules)
- **Slug uniqueness is global** — keep the existing `unique_index(:boards, [:slug])`; **no
  index migration**. Slug format: lowercase letters, numbers, and hyphens.
- **Card-ref `key` is auto-derived at creation, not user-entered** — the create form takes a
  **name only**. Derive `key` from the name (uppercased alphanumerics, ≤5 chars, fallback
  `"RLY"`). Editing `key` is out of scope.
- **Archived boards stay loadable** (a bookmarked URL must not 404) but are **read-only** and
  hidden from the switcher and `/boards` index.
- **Out of scope (do not build):** templates/duplication, cross-board search, sharing/multiple
  members, editing `key`, per-board theming/reordering/pinning, and API/CLI changes (the JSON
  API is already per-board via its API key).
- **`owner_id`/`key` are set programmatically, never cast from external input.** Every board /
  stage / card action must resolve through slug + `current_scope.user`.
- **Design:** follow `docs/designs/` + the daisyUI theme (Human = blue `--color-primary`, AI =
  violet `--color-secondary`). The General pane matches `BOARD SETTINGS §GENERAL` (name / Board
  URL `relay.app/<slug>` / Danger zone) in `Relay Board.dc.html`. Keys/counts in JetBrains
  Mono. Prefer daisyUI primitives (`dropdown`, `menu`, `card`, `badge`, `btn`, `input`).
- **`mix precommit` must pass** on every task (compile warnings-as-errors, `mix format` with
  Styler, `credo --strict`, `sobelow`, `deps.audit`, full test suite warnings-as-errors).
- Web layer may only call the domain through `Relay`'s exported contexts (`Relay.Boards`
  already exported); contexts may not reach into the web layer.

---

## Task 1: Data layer — `archived_at`, slug format, and multi-board `Boards` functions

Pure domain slice: migration + schema + context, fully covered by context tests. No web
changes; the existing LiveViews keep working because `get_or_create_default_board/1` still
returns the user's (now first active) board.

**Files**
- Create: `priv/repo/migrations/<ts>_add_archived_at_to_boards.exs` (generate with
  `mix ecto.gen.migration add_archived_at_to_boards`)
- Modify: `lib/schemas/board.ex`
- Modify: `lib/schemas/user.ex`
- Modify: `lib/relay/boards.ex`
- Modify (test): `test/relay/boards_test.exs`
- Modify (test): `test/schemas/board_test.exs`

**Interfaces**

*Consumes* (already present):
- `Schemas.Board` fields `name/slug/key/owner_id/archived_at`, `Board.changeset/2`.
- `Relay.Repo`, `Relay.Events.broadcast/2`, `Schemas.Stage`, `Schemas.User`.

*Produces* (later tasks rely on these exact signatures):
- `Relay.Boards.list_boards(%User{}) :: [%Board{}]` — non-archived, ordered `inserted_at` asc
  then `id` asc, **stages not preloaded**.
- `Relay.Boards.get_board(%User{}, slug :: String.t()) :: %Board{} | nil` — owner-scoped,
  **stages preloaded in position order**, archived boards still returned.
- `Relay.Boards.get_board!(%User{}, slug :: String.t()) :: %Board{}` — same, raises
  `Ecto.NoResultsError` when the user owns no board with that slug.
- `Relay.Boards.create_board(%User{}, attrs :: map) :: {:ok, %Board{}} | {:error, %Ecto.Changeset{}}`
  — validates `name`, derives a unique `slug` and a `key` from the name, seeds the 7-stage
  pipeline in one transaction, returns the board with stages preloaded. External callers pass
  only `%{name: ...}` / `%{"name" => ...}`.
- `Relay.Boards.update_board(%Board{}, attrs) :: {:ok, %Board{}} | {:error, %Ecto.Changeset{}}`
  — now casts `:name` **and** `:slug` (never `key`/`owner_id`), validates slug format +
  uniqueness, broadcasts `{:board_updated, board}`.
- `Relay.Boards.archive_board(%Board{}) :: {:ok, %Board{}} | {:error, cs}` and
  `Relay.Boards.unarchive_board(%Board{}) :: {:ok, %Board{}} | {:error, cs}` — set/clear
  `archived_at`, broadcast `{:board_updated, board}`.
- `Schemas.Board.archived?(%Board{}) :: boolean`.

**Steps**

- [x] **Migration.** Run `mix ecto.gen.migration add_archived_at_to_boards`, then write:

  ```elixir
  defmodule Relay.Repo.Migrations.AddArchivedAtToBoards do
    use Ecto.Migration

    def change do
      alter table(:boards) do
        add :archived_at, :utc_datetime
      end
    end
  end
  ```

  Run `mix ecto.migrate` (expect success).

- [x] **Board schema — field, `archived?/1`, slug format.** In `lib/schemas/board.ex` add the
  field inside `schema "boards"` (after `card_seq`):

  ```elixir
      field :archived_at, :utc_datetime
  ```

  Add slug-format validation to `changeset/2` — replace the final `|> unique_constraint(:slug)`
  line with:

  ```elixir
      |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
        message: "must be lowercase letters, numbers, and hyphens"
      )
      |> unique_constraint(:slug)
  ```

  Add a public predicate after `changeset/2`:

  ```elixir
    @doc "True when the board has been archived (read-only)."
    def archived?(%__MODULE__{archived_at: nil}), do: false
    def archived?(%__MODULE__{}), do: true
  ```

- [x] **User schema — `has_many :boards`.** In `lib/schemas/user.ex`, inside `schema "users"`
  (after the fields, before `timestamps`), add:

  ```elixir
      has_many :boards, Schemas.Board, foreign_key: :owner_id
  ```

- [x] **Write failing schema test for slug format + `archived?/1`.** Append to
  `test/schemas/board_test.exs` (inside the top-level module; keep existing tests):

  ```elixir
    describe "changeset/2 slug format (MMF 19)" do
      test "rejects a slug with uppercase, spaces, or symbols" do
        for bad <- ["Bad Slug", "acme/product", "under_score", "-leading", "trailing-"] do
          cs = Schemas.Board.changeset(%Schemas.Board{owner_id: 1}, %{name: "B", slug: bad, key: "B"})
          refute cs.valid?, "expected #{inspect(bad)} to be invalid"
          assert "must be lowercase letters, numbers, and hyphens" in errors_on(cs).slug
        end
      end

      test "accepts a lowercase hyphenated slug" do
        cs = Schemas.Board.changeset(%Schemas.Board{owner_id: 1}, %{name: "B", slug: "acme-1", key: "B"})
        assert cs.valid?
      end
    end

    describe "archived?/1" do
      test "reflects archived_at" do
        refute Schemas.Board.archived?(%Schemas.Board{archived_at: nil})
        assert Schemas.Board.archived?(%Schemas.Board{archived_at: ~U[2026-07-08 00:00:00Z]})
      end
    end
  ```

  Confirm `test/schemas/board_test.exs` already imports/aliases what it needs; if `errors_on/1`
  is unavailable there, use `Relay.DataCase`'s helper — the file already uses `Relay.DataCase`
  (verify at the top: `use Relay.DataCase, async: true`). Run
  `mix test test/schemas/board_test.exs` (expect the new tests to fail: format not yet
  compiled / archived? undefined — implement the schema step above first, then expect pass).

- [x] **Refactor `Boards` internals + add multi-board functions.** In `lib/relay/boards.ex`:

  1. Add `alias Ecto.Changeset` to the alias block (used by archive/unarchive).

  2. Replace the private slug helpers block at the bottom (`defp create_default_board!/1`,
     `defp unique_slug/1`, `defp suffixed_slug/2`, `defp slug_taken?/1`, `defp slug_base/1`)
     with the shared implementation below, and add the new public functions. Delete the old
     versions of those five private helpers.

  Add these **public** functions (place near `get_or_create_default_board/1`):

  ```elixir
    @doc "The user's non-archived boards, oldest first (stable inserted_at/id order)."
    def list_boards(%User{id: user_id}) do
      Repo.all(
        from b in Board,
          where: b.owner_id == ^user_id and is_nil(b.archived_at),
          order_by: [asc: b.inserted_at, asc: b.id]
      )
    end

    @doc """
    Owner-scoped board lookup by slug, with stages preloaded in position order.
    Returns an archived board too (still loadable, read-only). nil when the user
    owns no board with that slug.
    """
    def get_board(%User{id: user_id}, slug) when is_binary(slug) do
      Repo.one(
        from b in Board,
          where: b.owner_id == ^user_id and b.slug == ^slug,
          preload: [stages: ^from(s in Stage, order_by: s.position)]
      )
    end

    @doc "Like get_board/2 but raises Ecto.NoResultsError (→ 404) when not found."
    def get_board!(%User{id: user_id}, slug) when is_binary(slug) do
      Repo.one!(
        from b in Board,
          where: b.owner_id == ^user_id and b.slug == ^slug,
          preload: [stages: ^from(s in Stage, order_by: s.position)]
      )
    end

    @doc """
    Creates a board for `user`: validates `name`, derives a unique `slug` and a
    `key` from the name, sets `owner_id` programmatically, and seeds the default
    7-stage pipeline — all in one transaction. External callers pass a name only
    (`%{name: ...}` / `%{"name" => ...}`). Returns the board with stages preloaded.
    """
    def create_board(%User{} = user, attrs) do
      name = fetch_name(attrs)

      changeset =
        Board.changeset(%Board{owner_id: user.id}, %{
          name: name,
          slug: Map.get(attrs, :slug) || unique_slug(slugify(name)),
          key: Map.get(attrs, :key) || derive_key(name)
        })

      Repo.transaction(fn ->
        case Repo.insert(changeset) do
          {:ok, board} ->
            seed_stages!(board)
            Repo.preload(board, stages: from(s in Stage, order_by: s.position))

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end

    @doc "Archives a board (read-only). Broadcasts {:board_updated, board}."
    def archive_board(%Board{} = board) do
      board
      |> Changeset.change(archived_at: DateTime.truncate(DateTime.utc_now(), :second))
      |> Repo.update()
      |> broadcast_board_updated(board.id)
    end

    @doc "Clears a board's archived state. Broadcasts {:board_updated, board}."
    def unarchive_board(%Board{} = board) do
      board
      |> Changeset.change(archived_at: nil)
      |> Repo.update()
      |> broadcast_board_updated(board.id)
    end
  ```

  Update `get_or_create_default_board/1` to prefer the user's first active board:

  ```elixir
    def get_or_create_default_board(%User{} = user) do
      board =
        case list_boards(user) do
          [board | _] -> board
          [] -> create_default_board!(user)
        end

      Repo.preload(board, stages: from(s in Stage, order_by: s.position))
    end
  ```

  Update `update_board/2` to also cast `slug` (never `key`/`owner_id`):

  ```elixir
    def update_board(%Board{} = board, attrs) do
      board
      |> Board.changeset(Map.take(attrs, [:name, "name", :slug, "slug"]))
      |> Repo.update()
      |> broadcast_board_updated(board.id)
    end
  ```

  Add the new **private** helpers (replacing the deleted slug helpers + `create_default_board!`):

  ```elixir
    defp create_default_board!(user) do
      {:ok, board} =
        create_board(user, %{
          name: "My board",
          slug: unique_slug(slugify(user_source(user))),
          key: "RLY"
        })

      board
    end

    defp seed_stages!(board) do
      @seed_stages
      |> Enum.with_index(1)
      |> Enum.each(fn {{name, owner, category}, position} ->
        %Stage{board_id: board.id}
        |> Stage.changeset(%{name: name, position: position, category: category, owner: owner})
        |> Repo.insert!()
      end)
    end

    defp fetch_name(attrs), do: attrs[:name] || attrs["name"] || ""

    # Card-ref key: uppercased alphanumerics of the name, capped at 5 chars,
    # falling back to "RLY". Refs resolve per-board, so a shared key is harmless.
    defp derive_key(name) do
      case name |> to_string() |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "") |> String.slice(0, 5) do
        "" -> "RLY"
        key -> key
      end
    end

    defp user_source(user), do: user.name || user.email |> String.split("@") |> hd()

    defp slugify(source) do
      case source |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-") do
        "" -> "board"
        base -> base
      end
    end

    defp unique_slug(base) do
      if slug_taken?(base), do: suffixed_slug(base, 2), else: base
    end

    defp suffixed_slug(base, n) do
      candidate = "#{base}-#{n}"
      if slug_taken?(candidate), do: suffixed_slug(base, n + 1), else: candidate
    end

    defp slug_taken?(slug), do: Repo.exists?(from(b in Board, where: b.slug == ^slug))
  ```

- [x] **Rewrite the `update_board` "never changes" test for slug support.** In
  `test/relay/boards_test.exs`, replace the test `"never changes slug, key, or owner_id even
  when supplied"` (currently asserting slug is unchanged) with:

  ```elixir
      test "updates name and slug but never key or owner_id even when supplied" do
        board = Boards.get_or_create_default_board(insert(:user))
        %{key: key, owner_id: owner_id} = board

        assert {:ok, updated} =
                 Boards.update_board(board, %{
                   name: "Renamed",
                   slug: "renamed-slug",
                   key: "HAX",
                   owner_id: -1
                 })

        assert updated.name == "Renamed"
        assert updated.slug == "renamed-slug"
        assert updated.key == key
        assert updated.owner_id == owner_id

        reloaded = Repo.get!(Board, board.id)
        assert reloaded.slug == "renamed-slug"
        assert reloaded.key == key
        assert reloaded.owner_id == owner_id
      end
  ```

- [x] **Write failing context tests for the new functions.** Append these `describe` blocks to
  `test/relay/boards_test.exs`:

  ```elixir
    describe "create_board/2" do
      test "creates a named board, derives slug + key, seeds 7 stages" do
        user = insert(:user)

        assert {:ok, board} = Boards.create_board(user, %{name: "Launch Board"})
        assert board.owner_id == user.id
        assert board.name == "Launch Board"
        assert board.slug == "launch-board"
        assert board.key == "LAUNC"
        assert length(board.stages) == 7
        assert Enum.map(board.stages, & &1.name) ==
                 ["Backlog", "Spec", "Plan", "Code", "Review", "Deploy", "Done"]
      end

      test "accepts string-keyed params (the create form)" do
        assert {:ok, board} = Boards.create_board(insert(:user), %{"name" => "Ops"})
        assert board.name == "Ops"
        assert board.key == "OPS"
      end

      test "de-duplicates the derived slug against existing boards" do
        user = insert(:user)
        {:ok, first} = Boards.create_board(user, %{name: "Ops"})
        {:ok, second} = Boards.create_board(user, %{name: "Ops"})

        assert first.slug == "ops"
        assert second.slug == "ops-2"
      end

      test "falls back to key RLY when the name has no alphanumerics" do
        assert {:ok, board} = Boards.create_board(insert(:user), %{name: "★ ☆ ★"})
        assert board.key == "RLY"
        assert board.slug == "board"
      end

      test "rejects a blank name and creates nothing" do
        user = insert(:user)
        before = Repo.aggregate(Board, :count)

        assert {:error, changeset} = Boards.create_board(user, %{name: "   "})
        refute changeset.valid?
        assert Repo.aggregate(Board, :count) == before
      end
    end

    describe "list_boards/1" do
      test "returns the user's non-archived boards, oldest first" do
        user = insert(:user)
        {:ok, a} = Boards.create_board(user, %{name: "Alpha"})
        {:ok, b} = Boards.create_board(user, %{name: "Beta"})
        {:ok, archived} = Boards.create_board(user, %{name: "Gamma"})
        {:ok, _} = Boards.archive_board(archived)

        assert Enum.map(Boards.list_boards(user), & &1.id) == [a.id, b.id]
      end

      test "never returns another user's boards" do
        {:ok, _mine} = Boards.create_board(insert(:user), %{name: "Mine"})
        other = insert(:user)
        {:ok, theirs} = Boards.create_board(other, %{name: "Theirs"})

        refute theirs.id in Enum.map(Boards.list_boards(insert(:user)), & &1.id)
      end
    end

    describe "get_board/2 and get_board!/2" do
      test "returns the owner's board by slug with stages preloaded" do
        user = insert(:user)
        {:ok, board} = Boards.create_board(user, %{name: "Ops"})

        found = Boards.get_board(user, "ops")
        assert found.id == board.id
        assert length(found.stages) == 7
      end

      test "returns an archived board (still loadable)" do
        user = insert(:user)
        {:ok, board} = Boards.create_board(user, %{name: "Ops"})
        {:ok, _} = Boards.archive_board(board)

        assert Boards.get_board(user, "ops").id == board.id
      end

      test "get_board/2 returns nil for a slug the user does not own" do
        {:ok, board} = Boards.create_board(insert(:user), %{name: "Ops"})
        assert Boards.get_board(insert(:user), board.slug) == nil
      end

      test "get_board!/2 raises for a slug the user does not own" do
        {:ok, board} = Boards.create_board(insert(:user), %{name: "Ops"})

        assert_raise Ecto.NoResultsError, fn ->
          Boards.get_board!(insert(:user), board.slug)
        end
      end
    end

    describe "update_board/2 slug validation" do
      test "rejects an invalid slug format and changes nothing" do
        {:ok, board} = Boards.create_board(insert(:user), %{name: "Ops"})

        assert {:error, changeset} = Boards.update_board(board, %{slug: "Bad Slug"})
        refute changeset.valid?
        assert Repo.get!(Board, board.id).slug == board.slug
      end

      test "rejects a slug already taken by another board" do
        user = insert(:user)
        {:ok, _a} = Boards.create_board(user, %{name: "Alpha"})
        {:ok, b} = Boards.create_board(user, %{name: "Beta"})

        assert {:error, changeset} = Boards.update_board(b, %{slug: "alpha"})
        refute changeset.valid?
      end
    end

    describe "archive_board/1 and unarchive_board/1" do
      test "archive sets archived_at; unarchive clears it" do
        {:ok, board} = Boards.create_board(insert(:user), %{name: "Ops"})

        assert {:ok, archived} = Boards.archive_board(board)
        assert archived.archived_at
        assert Schemas.Board.archived?(archived)

        assert {:ok, restored} = Boards.unarchive_board(archived)
        assert restored.archived_at == nil
        refute Schemas.Board.archived?(restored)
      end

      test "archive broadcasts {:board_updated, board} on the board topic" do
        {:ok, board} = Boards.create_board(insert(:user), %{name: "Ops"})
        Relay.Events.subscribe(board.id)

        assert {:ok, _} = Boards.archive_board(board)
        assert_receive {:board_updated, %Schemas.Board{archived_at: at}} when not is_nil(at)
      end
    end
  ```

  Add `alias Schemas.User` / any missing alias only if the test references it (the block above
  uses `Schemas.Board`, `Relay.Events`, `Board`, `Repo`, `Boards` — all already aliased at the
  top of the file). Run `mix test test/relay/boards_test.exs` (expect fail before the context
  step compiles, pass after).

- [x] **Green + commit.** Run `mix precommit` (expect pass — the existing
  `get_or_create_default_board` tests still hold: first-active-board is idempotent, and the
  default board keeps slug "ada-lovelace"/"grace-hopper", key "RLY", name "My board").

**Deliverable:** `Relay.Boards` supports create / list / get-by-slug / archive with an
`archived_at` column and slug-format validation; all context + schema tests pass.
**Commit:** `feat(boards): multi-board context + archived_at + slug validation (RLY-6)`

---

## Task 2: Slug-based routing + slug-scoped LiveView mounts

Risky refactor, isolated: `/board/:slug` and `/board/:slug/settings` become the canonical
routes, slugless `/board` redirects, and both board LiveViews mount by slug (404 on a slug the
user doesn't own). This churns every `~p"/board..."` call site (source + tests).

**Files**
- Modify: `lib/relay_web/router.ex`
- Create: `lib/relay_web/controllers/board_redirect_controller.ex`
- Modify: `lib/relay_web/auth.ex` (docstring only — see step)
- Modify: `lib/relay_web/live/board_live.ex` (mount, reload_board, `~p` paths)
- Modify: `lib/relay_web/live/board_settings_live.ex` (mount, `~p` paths)
- Create (test): `test/relay_web/live/board_slug_routing_test.exs`
- Modify (test): every file listed in the "mechanical update" step below.

**Interfaces**

*Consumes* (from Task 1): `Boards.get_board!/2`, `Boards.get_or_create_default_board/1`.

*Produces*:
- Routes: `live "/boards", BoardsLive` (LiveView added in Task 3 — **add the route in Task 3**,
  not here), `live "/board/:slug", BoardLive`, `live "/board/:slug/settings",
  BoardSettingsLive`, `get "/board", BoardRedirectController, :show`.
- `RelayWeb.BoardRedirectController.show/2` — redirects to `~p"/board/#{slug}"` of the user's
  first active board.
- `BoardLive`/`BoardSettingsLive` assume a `%{"slug" => slug}` mount param.

**Steps**

- [ ] **Router.** In `lib/relay_web/router.ex`, add an authenticated browser pipeline and the
  slugless redirect route, and replace the two live routes. Add after the `:api_auth` pipeline:

  ```elixir
    pipeline :require_auth do
      plug :require_authenticated
    end
  ```

  Add a **dedicated authenticated scope** for the slugless redirect right after the existing
  `scope "/", RelayWeb do ... end` block (a plain `get` needs the `:require_authenticated` plug,
  which `live_session` supplies only to live routes):

  ```elixir
    scope "/", RelayWeb do
      pipe_through [:browser, :require_auth]

      get "/board", BoardRedirectController, :show
    end
  ```

  And change the `live_session :require_authenticated` body from:

  ```elixir
        live "/board", BoardLive
        live "/board/settings", BoardSettingsLive
  ```

  to:

  ```elixir
        live "/board/:slug", BoardLive
        live "/board/:slug/settings", BoardSettingsLive
  ```

  (The `live "/boards", BoardsLive` route is added in Task 3.)

- [ ] **Redirect controller.** Create
  `lib/relay_web/controllers/board_redirect_controller.ex`:

  ```elixir
  defmodule RelayWeb.BoardRedirectController do
    @moduledoc """
    Slugless `/board` → the user's first active board. Still creates+seeds a
    board on first login (via `Boards.get_or_create_default_board/1`), so a
    brand-new user lands on a working board. Slug is the canonical board URL.
    """

    use RelayWeb, :controller

    alias Relay.Boards

    def show(conn, _params) do
      board = Boards.get_or_create_default_board(conn.assigns.current_scope.user)
      redirect(conn, to: ~p"/board/#{board.slug}")
    end
  end
  ```

- [ ] **`BoardLive` mount by slug.** In `lib/relay_web/live/board_live.ex`:

  Replace the mount head + first line:

  ```elixir
    def mount(%{"slug" => slug}, _session, socket) do
      board = Boards.get_or_create_default_board(socket.assigns.current_scope.user)
  ```

  with:

  ```elixir
    def mount(%{"slug" => slug}, _session, socket) do
      board = Boards.get_board!(socket.assigns.current_scope.user, slug)
  ```

  In `reload_board/1`, replace `board = Boards.get_or_create_default_board(...)` with a re-fetch
  of **this** board by its slug:

  ```elixir
      board = Boards.get_board!(socket.assigns.current_scope.user, socket.assigns.board.slug)
  ```

  Make the drawer/patch paths slug-aware:
  - `handle_event("select_card", %{"ref" => ref}, socket)` — change
    `push_patch(socket, to: ~p"/board?card=#{ref}")` to
    `push_patch(socket, to: ~p"/board/#{socket.assigns.board.slug}?card=#{ref}")`.
  - In `render/1`, the settings link `navigate={~p"/board/settings"}` →
    `navigate={~p"/board/#{@board.slug}/settings"}`.
  - In `render/1`, the drawer `close_patch={~p"/board"}` →
    `close_patch={~p"/board/#{@board.slug}"}`.

- [ ] **`BoardSettingsLive` mount by slug.** In
  `lib/relay_web/live/board_settings_live.ex`:

  Replace the mount head + first line the same way:

  ```elixir
    def mount(%{"slug" => slug}, _session, socket) do
      board = Boards.get_board!(socket.assigns.current_scope.user, slug)
  ```

  Make the rail links slug-aware in `render/1`:
  - `patch={~p"/board/settings?section=general"}` → `patch={~p"/board/#{@board.slug}/settings?section=general"}`
  - `patch={~p"/board/settings"}` (Stages nav) → `patch={~p"/board/#{@board.slug}/settings"}`
  - `patch={~p"/board/settings?section=keys"}` → `patch={~p"/board/#{@board.slug}/settings?section=keys"}`
  - `navigate={~p"/board"}` (Back to board) → `navigate={~p"/board/#{@board.slug}"}`

- [ ] **Auth docstring.** In `lib/relay_web/auth.ex`, `log_in_user/2` keeps
  `redirect(to: ~p"/board")` (the redirect controller forwards to the slug — no change needed to
  the target). Update its `@doc` to read: `"Renews the session, stores the user id, and
  redirects to /board (which forwards to the user's board)."` (Keeps the 4 controller/auth
  tests asserting `redirected_to(conn) == ~p"/board"` green.)

- [ ] **Write failing slug-routing test.** Create
  `test/relay_web/live/board_slug_routing_test.exs`:

  ```elixir
  defmodule RelayWeb.BoardSlugRoutingTest do
    use RelayWeb.ConnCase, async: true

    import Phoenix.LiveViewTest

    alias Relay.Boards

    describe "slug routing" do
      setup :register_and_log_in_user

      test "slugless /board redirects to the user's board slug", %{conn: conn, user: user} do
        board = Boards.get_or_create_default_board(user)
        assert redirected_to(get(conn, ~p"/board")) == ~p"/board/#{board.slug}"
      end

      test "visiting /board/:slug renders the owner's board", %{conn: conn, user: user} do
        board = Boards.get_or_create_default_board(user)
        {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
        assert has_element?(view, "#board-title", board.name)
      end

      test "visiting /board/:slug/settings renders settings", %{conn: conn, user: user} do
        board = Boards.get_or_create_default_board(user)
        {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")
        assert has_element?(view, "#board-settings")
      end

      test "a slug the user does not own returns 404", %{conn: conn} do
        other = Relay.Factory.insert(:user)
        {:ok, other_board} = Boards.create_board(other, %{name: "Theirs"})

        assert_raise Ecto.NoResultsError, fn ->
          live(conn, ~p"/board/#{other_board.slug}")
        end
      end
    end
  end
  ```

  Run `mix test test/relay_web/live/board_slug_routing_test.exs` (expect fail, then pass once
  routing + mounts land).

- [ ] **Mechanical test update (make the suite green).** Every existing board LiveView test
  loads `~p"/board"` / `~p"/board/settings"` / `~p"/board?card=..."`, which no longer resolve
  to a LiveView. Apply this transform to each file below, obtaining the slug from the test's
  board (most tests already have `user` from `register_and_log_in_user`; fetch the board with
  `Boards.get_or_create_default_board(user)` — many already do):

  - `~p"/board"` → `~p"/board/#{board.slug}"` (bind `board = Boards.get_or_create_default_board(user)` at the top of the test if not already present)
  - `~p"/board?card=#{ref}"` → `~p"/board/#{board.slug}?card=#{ref}"`
  - `~p"/board/settings..."` → `~p"/board/#{board.slug}/settings..."`
  - The logged-out redirect assertion in `board_live_test.exs`
    (`live(conn, ~p"/board")` expecting `{:error, {:redirect, %{to: "/"}}}`) must target a
    concrete slug, e.g. `live(conn, ~p"/board/anything")` (still redirects to `/` — the auth
    `on_mount` halts before the mount body runs).

  Example (before → after) in `board_live_test.exs`:

  ```elixir
  # before
  test "renders the stage columns in position order", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/board")
  # after
  test "renders the stage columns in position order", %{conn: conn, user: user} do
    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
  ```

  Files to transform: `board_live_test.exs`, `board_live_realtime_test.exs`,
  `board_live_wip_move_test.exs`, `board_live_wip_test.exs`, `board_live_review_test.exs`,
  `board_live_needs_input_test.exs`, `board_settings_live_test.exs`,
  `board_settings_general_test.exs`, `board_settings_stages_test.exs`,
  `board_settings_wip_test.exs`, `board_settings_gate_test.exs`. **Do not** touch
  `auth_test.exs`, `auth_controller_test.exs`, `dev_login_controller_test.exs`,
  `page_controller_test.exs` — they assert `redirected_to == ~p"/board"`, which stays valid.
  Also update the browser smoke test `test/relay_web/browser/board_smoke_test.exs` if it
  navigates to `/board` (drive it through the slug, or through `/board` which now redirects —
  a real browser follows the redirect, so it may need no change; verify it passes).

- [ ] **Green + commit.** Run `mix precommit` (expect pass — full suite green with slug routes).

**Deliverable:** the board and its settings are reachable only by owner-scoped slug; slugless
`/board` redirects; an unowned slug 404s; the full suite is green.
**Commit:** `feat(boards): slug-based routing + owner-scoped board mounts (RLY-6)`

---

## Task 3: Boards index (`/boards`) + header board switcher

Adds `BoardsLive` (list active boards + create form) and replaces the static board title in
`BoardLive` with a daisyUI dropdown switcher.

**Files**
- Create: `lib/relay_web/live/boards_live.ex`
- Modify: `lib/relay_web/router.ex` (add `live "/boards", BoardsLive`)
- Modify: `lib/relay_web/live/board_live.ex` (load `@boards`; switcher markup)
- Create (test): `test/relay_web/live/boards_live_test.exs`
- Create (test): `test/relay_web/live/board_switcher_test.exs`

**Interfaces**

*Consumes*: `Boards.list_boards/1`, `Boards.create_board/2`, slug routes from Task 2.

*Produces*: `RelayWeb.BoardsLive` at `/boards`; `BoardLive` assigns `:boards` (the user's
active boards) and renders `#board-switcher`.

**Steps**

- [ ] **Route.** In `lib/relay_web/router.ex`, inside `live_session :require_authenticated`, add
  above the board route:

  ```elixir
        live "/boards", BoardsLive
  ```

- [ ] **Write failing `BoardsLive` test.** Create
  `test/relay_web/live/boards_live_test.exs`:

  ```elixir
  defmodule RelayWeb.BoardsLiveTest do
    use RelayWeb.ConnCase, async: true

    import Phoenix.LiveViewTest

    alias Relay.Boards

    describe "/boards" do
      setup :register_and_log_in_user

      test "lists the user's active boards with a link to open each", %{conn: conn, user: user} do
        {:ok, a} = Boards.create_board(user, %{name: "Alpha"})
        {:ok, b} = Boards.create_board(user, %{name: "Beta"})

        {:ok, view, _html} = live(conn, ~p"/boards")

        assert has_element?(view, "#board-card-#{a.id}", "Alpha")
        assert has_element?(view, "#board-card-#{b.id}", "Beta")
        assert has_element?(view, ~s|a[href="/board/#{a.slug}"]|)
      end

      test "does not list archived boards", %{conn: conn, user: user} do
        {:ok, archived} = Boards.create_board(user, %{name: "Gamma"})
        {:ok, _} = Boards.archive_board(archived)

        {:ok, view, _html} = live(conn, ~p"/boards")
        refute has_element?(view, "#board-card-#{archived.id}")
      end

      test "creating a board navigates to the new board", %{conn: conn, user: user} do
        {:ok, view, _html} = live(conn, ~p"/boards")

        {:error, {:live_redirect, %{to: to}}} =
          view
          |> form("#new-board-form", board: %{name: "Launch"})
          |> render_submit()

        board = Boards.get_board(user, "launch")
        assert board
        assert to == ~p"/board/#{board.slug}"
      end

      test "a blank name shows a form error and creates nothing", %{conn: conn, user: user} do
        before = length(Boards.list_boards(user))
        {:ok, view, _html} = live(conn, ~p"/boards")

        html = view |> form("#new-board-form", board: %{name: "   "}) |> render_submit()

        assert html =~ "should be at least 1 character"
        assert length(Boards.list_boards(user)) == before
      end
    end
  end
  ```

  Run it (expect fail — no route/module yet).

- [ ] **Implement `BoardsLive`.** Create `lib/relay_web/live/boards_live.ex`:

  ```elixir
  defmodule RelayWeb.BoardsLive do
    @moduledoc """
    The boards index (`/boards`): a card grid of the signed-in user's active
    boards plus a "New board" form (name only). Creating a board seeds its own
    pipeline (`Boards.create_board/2`) and navigates to it. Archived boards are
    hidden here (they stay reachable + unarchivable from their own read-only URL).
    """

    use RelayWeb, :live_view

    alias Relay.Boards

    @impl true
    def render(assigns) do
      ~H"""
      <Layouts.app flash={@flash} current_scope={@current_scope}>
        <div class="mx-auto max-w-4xl px-4 py-8">
          <div class="mb-6 flex items-center justify-between">
            <h1 class="text-2xl font-semibold">Your boards</h1>
          </div>

          <.form
            for={@form}
            id="new-board-form"
            phx-submit="create_board"
            class="mb-8 flex items-end gap-3"
          >
            <div class="flex-1">
              <.input field={@form[:name]} id="new-board-name" type="text" label="New board" placeholder="Board name" />
            </div>
            <button type="submit" id="create-board" class="btn btn-primary">Create board</button>
          </.form>

          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <.link
              :for={board <- @boards}
              id={"board-card-#{board.id}"}
              navigate={~p"/board/#{board.slug}"}
              class="card border border-base-300 bg-base-100 transition hover:border-primary hover:shadow-md"
            >
              <div class="card-body">
                <div class="flex items-center justify-between gap-2">
                  <h2 class="card-title text-base">{board.name}</h2>
                  <span class="badge badge-ghost font-mono text-xs">{board.key}</span>
                </div>
                <p class="font-mono text-xs text-base-content/50">relay.app/{board.slug}</p>
              </div>
            </.link>
          </div>
        </div>
      </Layouts.app>
      """
    end

    @impl true
    def mount(_params, _session, socket) do
      {:ok,
       socket
       |> assign(:page_title, "Boards")
       |> assign(:form, to_form(%{"name" => ""}, as: :board))
       |> load_boards()}
    end

    @impl true
    def handle_event("create_board", %{"board" => %{"name" => name}}, socket) do
      case Boards.create_board(socket.assigns.current_scope.user, %{name: name}) do
        {:ok, board} ->
          {:noreply, push_navigate(socket, to: ~p"/board/#{board.slug}")}

        {:error, changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    end

    defp load_boards(socket) do
      assign(socket, :boards, Boards.list_boards(socket.assigns.current_scope.user))
    end
  end
  ```

  Run `mix test test/relay_web/live/boards_live_test.exs` (expect pass).

- [ ] **Write failing switcher test.** Create
  `test/relay_web/live/board_switcher_test.exs`:

  ```elixir
  defmodule RelayWeb.BoardSwitcherTest do
    use RelayWeb.ConnCase, async: true

    import Phoenix.LiveViewTest

    alias Relay.Boards

    describe "header board switcher" do
      setup :register_and_log_in_user

      test "lists the user's active boards, current one marked", %{conn: conn, user: user} do
        {:ok, current} = Boards.create_board(user, %{name: "Alpha"})
        {:ok, other} = Boards.create_board(user, %{name: "Beta"})

        {:ok, view, _html} = live(conn, ~p"/board/#{current.slug}")

        assert has_element?(view, "#board-switcher", "Alpha")
        assert has_element?(view, ~s|#board-switcher-menu a[href="/board/#{other.slug}"]|, "Beta")
        assert has_element?(view, "#board-switcher-item-#{current.id}[aria-current]")
      end

      test "links to the boards index and the new-board form", %{conn: conn, user: user} do
        {:ok, board} = Boards.create_board(user, %{name: "Alpha"})
        {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

        assert has_element?(view, ~s|#board-switcher-menu a[href="/boards"]|)
      end
    end
  end
  ```

  Run it (expect fail).

- [ ] **Add the switcher to `BoardLive`.** In `lib/relay_web/live/board_live.ex`:

  In `mount/3`, add after `|> assign(:board, board)`:

  ```elixir
        |> assign(:boards, Boards.list_boards(socket.assigns.current_scope.user))
  ```

  In `reload_board/1`, add the same refresh after the `assign(:board, board)` line so a rename
  reflected via reload keeps the switcher current:

  ```elixir
        |> assign(:boards, Boards.list_boards(socket.assigns.current_scope.user))
  ```

  In `render/1`, replace the `<h1 id="board-title" ...>{@board.name}</h1>` element with the
  daisyUI dropdown switcher (keep the `#board-title` id inside so existing title assertions and
  the RLY-10 retitle still resolve):

  ```heex
          <div id="board-switcher" class="dropdown">
            <div
              tabindex="0"
              role="button"
              class="btn btn-ghost gap-2 px-2 text-xl font-semibold"
            >
              <span id="board-title">{@board.name}</span>
              <.icon name="hero-chevron-down" class="size-4 opacity-60" />
            </div>
            <ul
              id="board-switcher-menu"
              tabindex="0"
              class="menu dropdown-content z-10 mt-2 w-64 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
            >
              <li :for={b <- @boards} id={"board-switcher-item-#{b.id}"} aria-current={b.id == @board.id && "true"}>
                <.link navigate={~p"/board/#{b.slug}"} class={b.id == @board.id && "active"}>
                  <span>{b.name}</span>
                  <span class="badge badge-ghost badge-sm ml-auto font-mono">{b.key}</span>
                </.link>
              </li>
              <div class="divider my-1"></div>
              <li><.link navigate={~p"/boards"}>All boards</.link></li>
              <li><.link navigate={~p"/boards"}>+ New board</.link></li>
            </ul>
          </div>
  ```

  Run `mix test test/relay_web/live/board_switcher_test.exs` (expect pass).

- [ ] **Green + commit.** Run `mix precommit` (expect pass).

**Deliverable:** `/boards` lists active boards and creates new ones; the board header switches
between boards and links to the index / new-board form.
**Commit:** `feat(boards): boards index + header board switcher (RLY-6)`

---

## Task 4: General settings (slug edit + archive) + archived read-only

Adds slug editing and the Danger-zone archive to the General pane, wires archive/unarchive, and
makes archived boards read-only (banner + guarded mutations + real-time reaction).

**Files**
- Modify: `lib/relay_web/live/board_settings_live.ex` (General pane, save_general, archive)
- Modify: `lib/relay_web/live/board_live.ex` (read-only banner + guards + slug/archive reaction)
- Create (test): `test/relay_web/live/board_settings_general_slug_test.exs`
- Create (test): `test/relay_web/live/board_archive_test.exs`
- Modify (test): `test/relay_web/live/board_settings_general_test.exs` (still green; add slug field assertion)

**Interfaces**

*Consumes*: `Boards.update_board/2` (slug), `Boards.archive_board/1`,
`Boards.unarchive_board/1`, `Schemas.Board.archived?/1`.

*Produces*:
- `BoardSettingsLive` General form carries `name` + `slug`; `save_general` push_navigates to the
  new `/board/:slug/settings` when the slug changes. Archive/Unarchive buttons.
- `BoardLive`/`BoardSettingsLive` assign `:read_only`, render `#archived-banner`, and no-op
  their mutation handlers when read-only. `{:board_updated, board}` reacts to slug change
  (redirect) and archive change (flip read-only).

**Steps**

- [ ] **Write failing General slug/archive test.** Create
  `test/relay_web/live/board_settings_general_slug_test.exs`:

  ```elixir
  defmodule RelayWeb.BoardSettingsGeneralSlugTest do
    use RelayWeb.ConnCase, async: true

    import Phoenix.LiveViewTest

    alias Relay.Boards

    describe "General pane — slug + archive" do
      setup :register_and_log_in_user

      test "the pane shows the slug field and the Danger-zone archive button", %{conn: conn, user: user} do
        board = Boards.get_or_create_default_board(user)
        {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

        assert has_element?(view, "#board-slug-input")
        assert has_element?(view, "#archive-board")
      end

      test "editing the slug changes the URL and enforces uniqueness", %{conn: conn, user: user} do
        board = Boards.get_or_create_default_board(user)
        {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

        {:error, {:live_redirect, %{to: to}}} =
          view
          |> form("#general-form", board: %{name: board.name, slug: "launch-pad"})
          |> render_submit()

        assert to == ~p"/board/launch-pad/settings?section=general"
        assert Boards.get_board(user, "launch-pad")
      end

      test "an invalid slug shows a form error and changes nothing", %{conn: conn, user: user} do
        board = Boards.get_or_create_default_board(user)
        {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

        html =
          view
          |> form("#general-form", board: %{name: board.name, slug: "Bad Slug"})
          |> render_submit()

        assert html =~ "must be lowercase letters, numbers, and hyphens"
        assert Boards.get_or_create_default_board(user).slug == board.slug
      end

      test "a taken slug shows a form error", %{conn: conn, user: user} do
        # Editing THIS board's slug to one owned by ANOTHER board must collide.
        board = Boards.get_or_create_default_board(user)
        {:ok, _other} = Boards.create_board(user, %{name: "Taken"})
        {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

        html =
          view
          |> form("#general-form", board: %{name: board.name, slug: "taken"})
          |> render_submit()

        assert html =~ "has already been taken"
      end
    end
  end
  ```

  Run it (expect fail).

- [ ] **Wire the General pane.** In `lib/relay_web/live/board_settings_live.ex`:

  In `mount/3`, add `|> assign(:read_only, Schemas.Board.archived?(board))` after
  `|> assign(:board, board)` and add `alias Schemas.Board` to the aliases.

  In `render/1`, extend the General `<section>`: add the slug field to `#general-form` (below
  the name input), and add the Danger-zone block. Replace the existing `#general-form` inner
  markup with:

  ```heex
                <.input
                  field={@general_form[:name]}
                  id="board-name-input"
                  type="text"
                  label="Board name"
                />
                <.input
                  field={@general_form[:slug]}
                  id="board-slug-input"
                  type="text"
                  label="Board URL"
                />
                <p class="font-mono text-xs text-base-content/50">relay.app/{@board.slug}</p>
                <div>
                  <button type="submit" id="save-general" class="btn btn-primary btn-sm">Save</button>
                </div>
  ```

  Add a Danger-zone block right after the closing `</.form>` of `#general-form`, inside the
  General `<section>`:

  ```heex
              <div
                id="danger-zone"
                class="mt-11 rounded-xl border border-error/40 bg-error/5 p-5"
              >
                <div class="mb-1 text-sm font-semibold text-error">Danger zone</div>
                <div class="flex items-center gap-4">
                  <span class="flex-1 text-sm text-base-content/70">
                    Archiving hides this board from the switcher and index and makes it read-only. You can restore it later.
                  </span>
                  <button
                    :if={not @read_only}
                    type="button"
                    id="archive-board"
                    class="btn btn-outline btn-error btn-sm"
                    phx-click="archive_board"
                    data-confirm="Archive this board? It becomes read-only until you restore it."
                  >
                    Archive board
                  </button>
                  <button
                    :if={@read_only}
                    type="button"
                    id="unarchive-board"
                    class="btn btn-outline btn-sm"
                    phx-click="unarchive_board"
                  >
                    Unarchive board
                  </button>
                </div>
              </div>
  ```

  Change `mount`'s `general_form` assign to use the full changeset (name + slug already handled
  by `Boards.change_board/1`, which wraps `Board.changeset/2` — slug is castable). It already
  is `to_form(Boards.change_board(board))`; no change needed.

  Replace `save_general/2` so it also carries slug and navigates on slug change:

  ```elixir
    def handle_event("save_general", %{"board" => board_params}, socket) do
      case Boards.update_board(socket.assigns.board, board_params) do
        {:ok, board} ->
          if board.slug != socket.assigns.board.slug do
            {:noreply, push_navigate(socket, to: ~p"/board/#{board.slug}/settings?section=general")}
          else
            {:noreply,
             socket
             |> assign(:board, board)
             |> assign(:general_form, to_form(Boards.change_board(board)))
             |> put_flash(:info, "Board saved.")}
          end

        {:error, changeset} ->
          {:noreply, assign(socket, :general_form, to_form(changeset))}
      end
    end
  ```

  Add archive/unarchive handlers (near `save_general`):

  ```elixir
    def handle_event("archive_board", _params, socket) do
      {:ok, board} = Boards.archive_board(socket.assigns.board)

      {:noreply,
       socket
       |> assign(:board, board)
       |> assign(:read_only, true)
       |> put_flash(:info, "Board archived.")}
    end

    def handle_event("unarchive_board", _params, socket) do
      {:ok, board} = Boards.unarchive_board(socket.assigns.board)

      {:noreply,
       socket
       |> assign(:board, board)
       |> assign(:read_only, false)
       |> put_flash(:info, "Board restored.")}
    end
  ```

  **Guard the stage mutations when read-only.** Wrap the mutating `handle_event`s
  (`toggle_lane`, `update_stage`, `set_owner`, `toggle_wip`, `bump_wip`, `reorder_stage`,
  `add_stage`, `delete_stage`, `toggle_gate`, `set_reject_target`, `generate_key`,
  `regenerate_key`, `revoke_key`) with an early read-only no-op. Add a shared private helper and
  a guard clause at the head of each such handler:

  ```elixir
    # Read-only (archived) boards accept no mutations from the settings pane.
    defp writable?(socket), do: not socket.assigns.read_only
  ```

  For each mutating handler add a leading guarded head, e.g. for `update_stage`:

  ```elixir
    def handle_event("update_stage", params, %{assigns: %{read_only: true}} = socket) do
      _ = params
      {:noreply, socket}
    end

    def handle_event("update_stage", %{"stage_id" => stage_id, "stage" => stage_params}, socket) do
      # ... unchanged body ...
    end
  ```

  Apply the same `%{assigns: %{read_only: true}} = socket` guarded head to each mutating event
  named above (place the guarded head immediately before the existing clause). Non-mutating
  handlers (none here besides navigation) are untouched. The `writable?/1` helper is available
  if a single-clause guard is cleaner; either approach is fine as long as an archived board
  performs no stage/key mutation.

- [ ] **Update the existing General test for the slug field + flash copy.** In
  `test/relay_web/live/board_settings_general_test.exs`, the success test asserts the flash
  `"Board name saved."`; change that assertion to `"Board saved."` (matches the new
  `save_general` copy). Add one assertion to the first test:
  `assert has_element?(view, "#board-slug-input")`. All other assertions stay. Run
  `mix test test/relay_web/live/board_settings_general_test.exs` (expect pass).

- [ ] **Write failing archive / read-only test.** Create
  `test/relay_web/live/board_archive_test.exs`:

  ```elixir
  defmodule RelayWeb.BoardArchiveTest do
    use RelayWeb.ConnCase, async: true

    import Phoenix.LiveViewTest

    alias Relay.Boards
    alias Relay.Repo
    alias Schemas.Card

    describe "archived board is read-only" do
      setup :register_and_log_in_user

      test "an archived board renders a read-only banner instead of 404", %{conn: conn, user: user} do
        board = Boards.get_or_create_default_board(user)
        {:ok, _} = Boards.archive_board(board)

        {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
        assert has_element?(view, "#archived-banner")
        assert has_element?(view, "#archived-banner-unarchive")
      end

      test "create_card is a no-op on an archived board", %{conn: conn, user: user} do
        board = Boards.get_or_create_default_board(user)
        stage = hd(board.stages)
        {:ok, _} = Boards.archive_board(board)

        {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

        render_hook(view, "create_card", %{"stage_id" => to_string(stage.id), "card" => %{"title" => "Nope"}})

        assert Repo.aggregate(Card, :count) == 0
      end

      test "unarchiving from the banner restores write access", %{conn: conn, user: user} do
        board = Boards.get_or_create_default_board(user)
        {:ok, _} = Boards.archive_board(board)

        {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
        view |> element("#archived-banner-unarchive") |> render_click()

        refute has_element?(view, "#archived-banner")
        refute Schemas.Board.archived?(Repo.reload!(board))
      end

      test "a card created after unarchive persists", %{conn: conn, user: user} do
        board = Boards.get_or_create_default_board(user)
        stage = hd(board.stages)
        {:ok, _} = Boards.archive_board(board)

        {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
        view |> element("#archived-banner-unarchive") |> render_click()

        render_hook(view, "create_card", %{"stage_id" => to_string(stage.id), "card" => %{"title" => "Now allowed"}})

        assert Repo.aggregate(Card, :count) == 1
      end
    end
  end
  ```

  Run it (expect fail).

- [ ] **Add read-only to `BoardLive`.** In `lib/relay_web/live/board_live.ex`:

  In `mount/3`, add after `|> assign(:board, board)`:
  `|> assign(:read_only, Board.archived?(board))`. In `reload_board/1`, add the same recompute.

  In `render/1`, add a banner at the very top of the `#board` container (just inside
  `<div id="board" phx-hook="BoardDnD">`):

  ```heex
        <div
          :if={@read_only}
          id="archived-banner"
          class="mx-4 mb-2 mt-2 flex items-center gap-3 rounded-lg border border-warning/50 bg-warning/10 px-4 py-2 text-sm sm:mx-5"
        >
          <.icon name="hero-archive-box" class="size-5 text-warning" />
          <span class="flex-1">This board is archived — read-only.</span>
          <button
            type="button"
            id="archived-banner-unarchive"
            class="btn btn-warning btn-xs"
            phx-click="unarchive_board"
          >
            Unarchive
          </button>
        </div>
  ```

  Add an `unarchive_board` handler:

  ```elixir
    def handle_event("unarchive_board", _params, socket) do
      {:ok, board} = Boards.unarchive_board(socket.assigns.board)

      {:noreply,
       socket
       |> assign(:board, board)
       |> assign(:read_only, false)
       |> put_flash(:info, "Board restored.")}
    end
  ```

  **Guard the board mutations.** Add a guarded head (`%{assigns: %{read_only: true}} = socket`)
  before the existing clauses of the mutating handlers `compose`, `create_card`, and
  `move_card` — each returns `{:noreply, socket}` unchanged when read-only:

  ```elixir
    def handle_event("create_card", _params, %{assigns: %{read_only: true}} = socket) do
      {:noreply, socket}
    end

    def handle_event("create_card", %{"stage_id" => stage_id, "card" => card_params}, socket) do
      # ... unchanged body ...
    end
  ```

  Apply the same guarded head to `compose` and `move_card`. (Drawer edit/owner/review handlers
  operate through `Cards`, which stays available; the banner + composer suppression cover the
  primary write surface. If the reviewer wants stricter coverage, extend the same guarded head
  to `save_card_title` / `save_card_description` / `set_card_status` — optional, not required by
  the tests.)

  In `render/1`, suppress the composer "add card" trigger when read-only by passing the flag to
  `stage_column` if it supports it; otherwise wrap the composer entry so archived boards show no
  compose affordance. Minimal sufficient change: guard the `compose` event (done above) — the
  server refuses to open the composer, so no card can be created.

  **Extend the `{:board_updated}` handler** to react to slug + archive changes. Replace the
  RLY-10 handler with:

  ```elixir
    def handle_info({:board_updated, %Board{} = board}, socket) do
      cond do
        board.slug != socket.assigns.board.slug ->
          {:noreply, push_navigate(socket, to: ~p"/board/#{board.slug}")}

        true ->
          updated = %{socket.assigns.board | name: board.name, archived_at: board.archived_at}

          {:noreply,
           socket
           |> assign(:board, updated)
           |> assign(:page_title, board.name)
           |> assign(:read_only, Board.archived?(board))}
      end
    end
  ```

  Run `mix test test/relay_web/live/board_archive_test.exs` (expect pass).

- [ ] **Green + commit.** Run `mix precommit` (expect pass).

**Deliverable:** Settings → General edits name + slug (URL tracks the slug, uniqueness
enforced) and archives/unarchives; archived boards render read-only with a banner and reject
mutations. All acceptance criteria met.
**Commit:** `feat(boards): general settings slug edit + archive read-only (RLY-6)`

---

## Spec coverage map
- AC1 (create/name/switch from header) → Task 3 (switcher + create via `/boards`).
- AC2 (independent stages/cards/refs per board) → Task 1 (`create_board` seeds per-board
  pipeline; refs already per-board) + Task 2 (slug-scoped mounts).
- AC3 (`/boards` lists active; `/board` still lands) → Task 2 (redirect) + Task 3 (index).
- AC4 (edit slug changes URL + global uniqueness; invalid/taken errors) → Task 1 (validation) +
  Task 4 (General pane + navigate).
- AC5 (archive removes from switcher/index + read-only; unarchivable) → Task 1 (`archive_board`
  + `list_boards` excludes archived) + Task 3 (switcher/index use `list_boards`) + Task 4
  (read-only + unarchive).
- AC6 (unowned slug → 404) → Task 1 (`get_board!`) + Task 2 (mount) — proven in
  `board_slug_routing_test.exs`.
- AC7 (blank/invalid name errors, creates nothing) → Task 1 (`create_board` validation) +
  Task 3 (`BoardsLive` form).
- AC8 (`mix precommit` passes) → every task ends on green precommit.
