# Plan: MMF 08 — Board API key

**Spec:** `docs/superpowers/specs/2026-07-07-board-api-keys-design.md`
**Development:** trunk-based on `main`. One commit per task, message given at the end of each task.

## Goal

A board owner can mint, regenerate, and revoke a single API key for their board from a new
`/board/settings` page. The raw token (`relay_<prefix>_<secret>`) is revealed **exactly once**
at creation/regeneration; only a SHA-256 hash of the secret is persisted. A new
`Relay.ApiKeys` context also ships `authenticate/1` (raw token → board) so MMF 09 can
authenticate API requests — but no request authentication is wired up in this MMF.

## Architecture

- **New domain context `Relay.ApiKeys`** (`lib/relay/api_keys.ex`) — its own `Boundary`
  sub-boundary, exported from `Relay` in `lib/relay.ex` (exactly like `Relay.Boards`).
- **New schema `Schemas.ApiKey`** (`lib/schemas/api_key.ex`) in the shared `Schemas`
  boundary (ADR 0002), exported from `lib/schemas.ex`. Data shape + changeset only;
  token generation/hashing logic lives in the context.
- **New LiveView `RelayWeb.BoardSettingsLive`** (`lib/relay_web/live/board_settings_live.ex`)
  at `/board/settings`, inside the existing `:require_authenticated` `live_session`.
  Authorization is inherent: the page always operates on
  `Boards.get_or_create_default_board(current_scope.user)` — a user can only ever see/manage
  their own board's key (one board per user today).
- **Token format:** `relay_<prefix>_<secret>` where `prefix` = 6 random bytes hex-encoded
  (12 chars, stored in the clear, unique — used for lookup and masked display) and
  `secret` = 32 random bytes hex-encoded (64 chars, stored only as
  `Base.encode16(:crypto.hash(:sha256, secret), case: :lower)`). Hex encoding guarantees no
  `_` in the prefix, so `String.split(token, "_", parts: 3)` parses unambiguously.
  SHA-256 (not bcrypt) is correct for high-entropy machine tokens. Comparison uses
  `Plug.Crypto.secure_compare/2` (constant-time; `plug_crypto` is already a Phoenix
  dependency — an external hex app, so no boundary concern).
- **Single-key invariant:** a unique index on `api_keys.board_id`. `create_key/2` returns
  `{:error, :already_exists}` when a key exists; the UI replaces keys via `regenerate/1`
  (same row, new secret) and never offers Generate while a key exists.

## Tech

Elixir/Phoenix 1.8, LiveView 1.1, Ecto/Postgres, `boundary`, ExMachina factories, daisyUI +
Tailwind v4, `Phoenix.LiveViewTest` + LazyHTML for LiveView tests. Colocated JS hook for
copy-to-clipboard.

## Global constraints (project rules — follow exactly)

- **`mix precommit` is REQUIRED on every development cycle and must pass before work is
  considered done.** It runs compile (warnings as errors), `mix format` (with Styler),
  `mix credo --strict`, `mix sobelow`, `mix deps.audit`, and the full test suite (warnings
  as errors). Never commit with a failing `mix precommit`.
- **Boundaries are enforced by the compiler** — a boundary violation fails compilation. New
  contexts get `use Boundary` and must be added to `Relay`'s `exports` in `lib/relay.ex`.
- **Secrets are stored hashed, never plaintext.** The raw API secret exists only in the
  return value of `create_key/2` / `regenerate/1` and in socket assigns while revealed —
  never in the DB, never in logs.
- **Programmatic fields are never cast.** `board_id`, `created_by_id`, `token_prefix`,
  `token_hash`, `last_four` are set on the struct / via `Ecto.Changeset.change/2`, never
  listed in `cast` (matches the `Schemas.CardOwner` pattern).
- **Always** use the imported `<.input>` component for form inputs and `<.icon>` for icons
  (never `Heroicons` modules).
- **Always** begin LiveView templates with
  `<Layouts.app flash={@flash} current_scope={@current_scope}>` wrapping all inner content.
- Predicate functions end in `?`, never start with `is_`.
- Never `String.to_atom/1` on user input.
- Colocated JS hook names **must** start with a `.` prefix (e.g. `.CopyKey`) and are written
  as `<script :type={Phoenix.LiveView.ColocatedHook} name=".CopyKey">` inside the template —
  never raw `<script>` tags.
- Prefer daisyUI components (`btn`, `card`, `badge`, `join`, `alert`, …); give key elements
  stable DOM ids for tests.
- TDD per step: write the failing test, run it and watch it fail, write the minimal
  implementation, run it green, then `mix precommit`, then commit.
- Generate migrations with `mix ecto.gen.migration <name>`; run with `mix ecto.migrate`.

---

### Task 1: `Relay.ApiKeys` context + `Schemas.ApiKey` (domain slice)

**Files**

- `priv/repo/migrations/<timestamp>_create_api_keys.exs` — new (generate with
  `mix ecto.gen.migration create_api_keys`)
- `lib/schemas/api_key.ex` — new
- `lib/schemas.ex` — edit (export `ApiKey`)
- `lib/relay/api_keys.ex` — new
- `lib/relay.ex` — edit (export `ApiKeys`)
- `test/support/factory.ex` — edit (add `api_key_factory`)
- `test/relay/api_keys_test.exs` — new

**Interfaces**

Consumes:
- `Relay.Repo` (Ecto repo)
- `Schemas.Board` / `Schemas.User` structs (persisted; `insert(:board)` / `insert(:user)`
  factories exist in `test/support/factory.ex`)
- `Plug.Crypto.secure_compare/2`, `:crypto.strong_rand_bytes/1`, `:crypto.hash/2`

Produces (the complete public API of `Relay.ApiKeys`; Task 2 and MMF 09 call these — keep
the signatures exactly as written):
- `create_key(%Schemas.Board{}, %Schemas.User{}) :: {:ok, %{api_key: %Schemas.ApiKey{}, token: String.t()}} | {:error, :already_exists}`
- `get_key(%Schemas.Board{}) :: %Schemas.ApiKey{} | nil`
- `regenerate(%Schemas.ApiKey{}) :: {:ok, %{api_key: %Schemas.ApiKey{}, token: String.t()}}`
- `revoke(%Schemas.ApiKey{}) :: {:ok, %Schemas.ApiKey{}}`
- `authenticate(String.t()) :: {:ok, %Schemas.Board{}} | :error` (bumps `last_used_at` on
  success — this is what MMF 09 will call)

**Steps**

- [x] Write the failing context test at `test/relay/api_keys_test.exs`:

  ```elixir
  defmodule Relay.ApiKeysTest do
    use Relay.DataCase, async: true

    alias Relay.ApiKeys
    alias Schemas.ApiKey

    describe "create_key/2" do
      test "creates the board's key and returns the raw token exactly once" do
        board = insert(:board)
        user = insert(:user)

        assert {:ok, %{api_key: %ApiKey{} = key, token: token}} = ApiKeys.create_key(board, user)

        assert token =~ ~r/^relay_[0-9a-f]{12}_[0-9a-f]{64}$/
        ["relay", prefix, secret] = String.split(token, "_", parts: 3)
        assert key.board_id == board.id
        assert key.created_by_id == user.id
        assert key.name == "Board API key"
        assert key.token_prefix == prefix
        assert key.last_four == String.slice(secret, -4, 4)
        assert key.last_used_at == nil
      end

      test "stores only a SHA-256 hash — the raw secret is never persisted" do
        {:ok, %{api_key: key, token: token}} = ApiKeys.create_key(insert(:board), insert(:user))
        ["relay", _prefix, secret] = String.split(token, "_", parts: 3)

        reloaded = Repo.get!(ApiKey, key.id)
        assert reloaded.token_hash == Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
        refute inspect(Map.from_struct(reloaded)) =~ secret
      end

      test "errors when the board already has a key (single-key invariant)" do
        board = insert(:board)
        user = insert(:user)
        {:ok, _created} = ApiKeys.create_key(board, user)

        assert {:error, :already_exists} = ApiKeys.create_key(board, user)
        assert Repo.aggregate(ApiKey, :count) == 1
      end
    end

    describe "get_key/1" do
      test "returns the board's key, or nil when none exists" do
        board = insert(:board)
        assert ApiKeys.get_key(board) == nil

        {:ok, %{api_key: key}} = ApiKeys.create_key(board, insert(:user))

        assert ApiKeys.get_key(board).id == key.id
        assert ApiKeys.get_key(insert(:board)) == nil
      end
    end

    describe "authenticate/1" do
      test "returns the key's board for a valid raw token and bumps last_used_at" do
        board = insert(:board)
        {:ok, %{token: token}} = ApiKeys.create_key(board, insert(:user))

        assert {:ok, authed_board} = ApiKeys.authenticate(token)
        assert authed_board.id == board.id
        assert %DateTime{} = ApiKeys.get_key(board).last_used_at
      end

      test "rejects a token with a known prefix but the wrong secret" do
        board = insert(:board)
        {:ok, %{api_key: key}} = ApiKeys.create_key(board, insert(:user))

        forged = "relay_#{key.token_prefix}_#{String.duplicate("0", 64)}"
        assert :error = ApiKeys.authenticate(forged)
        assert ApiKeys.get_key(board).last_used_at == nil
      end

      test "rejects unknown prefixes and malformed tokens" do
        assert :error = ApiKeys.authenticate("relay_deadbeef0000_" <> String.duplicate("a", 64))
        assert :error = ApiKeys.authenticate("not-a-token")
        assert :error = ApiKeys.authenticate("relay_missingsecret")
        assert :error = ApiKeys.authenticate("")
      end

      test "rejects a revoked key's token" do
        {:ok, %{api_key: key, token: token}} = ApiKeys.create_key(insert(:board), insert(:user))
        {:ok, _revoked} = ApiKeys.revoke(key)

        assert :error = ApiKeys.authenticate(token)
      end
    end

    describe "regenerate/1" do
      test "replaces the secret on the same row; the old token stops authenticating" do
        board = insert(:board)
        {:ok, %{api_key: key, token: old_token}} = ApiKeys.create_key(board, insert(:user))

        assert {:ok, %{api_key: new_key, token: new_token}} = ApiKeys.regenerate(key)

        assert new_key.id == key.id
        refute new_token == old_token
        refute new_key.token_prefix == key.token_prefix
        assert :error = ApiKeys.authenticate(old_token)
        assert {:ok, authed_board} = ApiKeys.authenticate(new_token)
        assert authed_board.id == board.id
        assert Repo.aggregate(ApiKey, :count) == 1
      end

      test "resets last_used_at" do
        {:ok, %{api_key: key, token: token}} = ApiKeys.create_key(insert(:board), insert(:user))
        {:ok, _board} = ApiKeys.authenticate(token)
        key = Repo.get!(ApiKey, key.id)
        assert key.last_used_at

        {:ok, %{api_key: new_key}} = ApiKeys.regenerate(key)
        assert new_key.last_used_at == nil
      end
    end

    describe "revoke/1" do
      test "deletes the key" do
        board = insert(:board)
        {:ok, %{api_key: key}} = ApiKeys.create_key(board, insert(:user))

        assert {:ok, %ApiKey{}} = ApiKeys.revoke(key)
        assert ApiKeys.get_key(board) == nil
        assert Repo.aggregate(ApiKey, :count) == 0
      end
    end
  end
  ```

  Run `mix test test/relay/api_keys_test.exs` — it must fail (modules don't exist yet;
  expect a compile error, which counts as the red step here).

- [x] Generate the migration with `mix ecto.gen.migration create_api_keys` and fill in the
  generated file (name will be `priv/repo/migrations/<timestamp>_create_api_keys.exs`):

  ```elixir
  defmodule Relay.Repo.Migrations.CreateApiKeys do
    use Ecto.Migration

    def change do
      create table(:api_keys) do
        add :board_id, references(:boards, on_delete: :delete_all), null: false
        add :name, :string, null: false
        add :token_prefix, :string, null: false
        add :token_hash, :string, null: false
        add :last_four, :string, null: false
        add :created_by_id, references(:users, on_delete: :nilify_all)
        add :last_used_at, :utc_datetime

        timestamps(type: :utc_datetime)
      end

      # Single active key per board (MMF 08 decision) — going multi-key later
      # is just relaxing this to a plain index, not a reshape.
      create unique_index(:api_keys, [:board_id])
      create unique_index(:api_keys, [:token_prefix])
      create index(:api_keys, [:created_by_id])
    end
  end
  ```

  Run `mix ecto.migrate`.

- [x] Create `lib/schemas/api_key.ex` (all fields are programmatic — nothing is cast;
  mirrors the `Schemas.CardOwner` changeset style):

  ```elixir
  defmodule Schemas.ApiKey do
    @moduledoc """
    A board's API key (MMF 08). One active key per board for now (unique
    index on `board_id`); the table keeps `board_id` so going multi-key
    later is a constraint change, not a reshape. The raw token is
    `relay_<token_prefix>_<secret>`: `token_prefix` is a public random id
    stored in the clear (lookup + masked display), the secret is stored
    only as a SHA-256 hash in `token_hash` (`last_four` supports the
    masked display). All fields are set programmatically by
    `Relay.ApiKeys`, never cast from input.
    """

    use Ecto.Schema

    import Ecto.Changeset

    schema "api_keys" do
      field :name, :string
      field :token_prefix, :string
      field :token_hash, :string
      field :last_four, :string
      field :last_used_at, :utc_datetime

      belongs_to :board, Schemas.Board
      belongs_to :created_by, Schemas.User, foreign_key: :created_by_id

      timestamps(type: :utc_datetime)
    end

    @doc "Validates a programmatically-built key row (nothing is cast from input)."
    def changeset(api_key) do
      api_key
      |> change()
      |> validate_required([:board_id, :name, :token_prefix, :token_hash, :last_four])
      |> unique_constraint(:board_id)
      |> unique_constraint(:token_prefix)
      |> foreign_key_constraint(:board_id)
      |> foreign_key_constraint(:created_by_id)
    end
  end
  ```

- [x] Export the schema from `lib/schemas.ex` — change the `use Boundary` line to:

  ```elixir
  use Boundary, deps: [], exports: [Activity, ApiKey, Board, Card, CardOwner, Comment, Scope, Stage, User]
  ```

- [x] Create `lib/relay/api_keys.ex`:

  ```elixir
  defmodule Relay.ApiKeys do
    @moduledoc """
    The ApiKeys context (MMF 08): a board's single API key.

    Raw tokens look like `relay_<prefix>_<secret>` (both parts hex, so the
    token splits unambiguously on `_`). The secret is returned exactly once
    from `create_key/2` / `regenerate/1` and stored only as a SHA-256 hash —
    fast and correct for high-entropy machine tokens (bcrypt is for
    passwords). `authenticate/1` is the entry point MMF 09's API auth will
    call: prefix lookup, then constant-time hash comparison.
    """

    use Boundary, deps: [Relay.Repo, Schemas]

    alias Relay.Repo
    alias Schemas.ApiKey
    alias Schemas.Board
    alias Schemas.User

    @default_name "Board API key"
    @prefix_bytes 6
    @secret_bytes 32

    @doc """
    Creates the board's API key. Returns `{:ok, %{api_key: key, token: raw}}` —
    the only place the raw token ever exists; it is never persisted or
    re-retrievable. Returns `{:error, :already_exists}` if the board already
    has a key (single-key invariant — the UI replaces keys via `regenerate/1`).
    """
    def create_key(%Board{} = board, %User{} = creator) do
      {prefix, secret, raw} = generate_token()

      changeset =
        ApiKey.changeset(%ApiKey{
          board_id: board.id,
          created_by_id: creator.id,
          name: @default_name,
          token_prefix: prefix,
          token_hash: hash_secret(secret),
          last_four: String.slice(secret, -4, 4)
        })

      case Repo.insert(changeset) do
        {:ok, key} -> {:ok, %{api_key: key, token: raw}}
        {:error, _changeset} -> {:error, :already_exists}
      end
    end

    @doc "Returns the board's API key, or nil when none exists."
    def get_key(%Board{id: board_id}), do: Repo.get_by(ApiKey, board_id: board_id)

    @doc """
    Replaces the key's secret in place (same row, new prefix + hash, cleared
    `last_used_at`) and returns `{:ok, %{api_key: key, token: raw}}` with the
    new raw token — revealed exactly once. The old token stops authenticating
    immediately.
    """
    def regenerate(%ApiKey{} = key) do
      {prefix, secret, raw} = generate_token()

      key =
        key
        |> Ecto.Changeset.change(
          token_prefix: prefix,
          token_hash: hash_secret(secret),
          last_four: String.slice(secret, -4, 4),
          last_used_at: nil
        )
        |> Repo.update!()

      {:ok, %{api_key: key, token: raw}}
    end

    @doc "Revokes (deletes) the key. Its token stops authenticating immediately."
    def revoke(%ApiKey{} = key), do: Repo.delete(key)

    @doc """
    Authenticates a raw `relay_<prefix>_<secret>` token: looks the key up by
    prefix, constant-time compares the secret's hash, bumps `last_used_at`,
    and returns `{:ok, board}`. Any malformed, unknown, or revoked token
    returns `:error`. This is what MMF 09's API authentication calls.
    """
    def authenticate(raw_token) when is_binary(raw_token) do
      with ["relay", prefix, secret] <- String.split(raw_token, "_", parts: 3),
           %ApiKey{} = key <- Repo.get_by(ApiKey, token_prefix: prefix),
           true <- Plug.Crypto.secure_compare(hash_secret(secret), key.token_hash) do
        key
        |> Ecto.Changeset.change(last_used_at: DateTime.truncate(DateTime.utc_now(), :second))
        |> Repo.update!()

        {:ok, Repo.preload(key, :board).board}
      else
        _not_authenticated -> :error
      end
    end

    defp generate_token do
      prefix = random_hex(@prefix_bytes)
      secret = random_hex(@secret_bytes)
      {prefix, secret, "relay_#{prefix}_#{secret}"}
    end

    defp random_hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    defp hash_secret(secret), do: Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
  end
  ```

- [x] Export the context from `lib/relay.ex` — change the `use Boundary` block to:

  ```elixir
  use Boundary,
    deps: [Schemas],
    exports: [Repo, Mailer, Accounts, Activity, ApiKeys, Boards, Cards]
  ```

- [x] Add an `api_key_factory` to `test/support/factory.ex` (for MMF 09 and any test that
  needs a persisted key without caring about the raw token — tests that need the raw token
  call `ApiKeys.create_key/2` directly). Add after `board_factory`:

  ```elixir
  # A persisted key whose raw token is intentionally unknown — use
  # Relay.ApiKeys.create_key/2 in tests that need the raw secret.
  def api_key_factory do
    secret = 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    %Schemas.ApiKey{
      name: "Board API key",
      token_prefix: sequence(:token_prefix, &String.pad_leading("#{&1}", 12, "0")),
      token_hash: Base.encode16(:crypto.hash(:sha256, secret), case: :lower),
      last_four: String.slice(secret, -4, 4),
      board: build(:board),
      created_by: build(:user)
    }
  end
  ```

- [x] Run `mix test test/relay/api_keys_test.exs` — all green. Then `mix test` (full
  suite), then `mix precommit` — fix anything it flags (formatting, credo, sobelow) before
  committing.

**Deliverable (independently testable):** `Relay.ApiKeys` is fully unit-tested via
`mix test test/relay/api_keys_test.exs`: create reveals the raw token once and persists
only the hash; authenticate accepts the valid token (bumping `last_used_at`) and rejects
forged/malformed/revoked tokens; regenerate invalidates the old secret on the same row;
revoke deletes; the single-key invariant holds at the DB level.

**Commit message:**

```
feat(api-keys): Relay.ApiKeys context + Schemas.ApiKey (MMF 08 domain)

One hashed API key per board: create (raw token revealed once),
get_key, regenerate, revoke, and authenticate/1 for MMF 09.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vr8Fre7pvjAxbBQsM6SoB7
```

---

### Task 2: `/board/settings` LiveView with the API key pane (web slice)

**Files**

- `lib/relay_web/router.ex` — edit (add the route)
- `lib/relay_web/live/board_settings_live.ex` — new
- `lib/relay_web/live/board_live.ex` — edit (add a settings gear link so the page is reachable)
- `test/relay_web/live/board_settings_live_test.exs` — new

**Interfaces**

Consumes (from Task 1 — signatures must match exactly):
- `Relay.Boards.get_or_create_default_board(%Schemas.User{}) :: %Schemas.Board{}`
- `Relay.ApiKeys.create_key(%Schemas.Board{}, %Schemas.User{}) :: {:ok, %{api_key: %Schemas.ApiKey{}, token: String.t()}} | {:error, :already_exists}`
- `Relay.ApiKeys.get_key(%Schemas.Board{}) :: %Schemas.ApiKey{} | nil`
- `Relay.ApiKeys.regenerate(%Schemas.ApiKey{}) :: {:ok, %{api_key: %Schemas.ApiKey{}, token: String.t()}}`
- `Relay.ApiKeys.revoke(%Schemas.ApiKey{}) :: {:ok, %Schemas.ApiKey{}}`
- `socket.assigns.current_scope` (`%Schemas.Scope{user: %Schemas.User{}}`) provided by the
  `:require_authenticated` live_session (`RelayWeb.Auth`)
- Test helpers from `RelayWeb.ConnCase`: `register_and_log_in_user/1`

Produces:
- `GET /board/settings` (authenticated LiveView route, `RelayWeb.BoardSettingsLive`)
- Stable DOM ids for tests and future settings MMFs (12/10b/19): `#api-key-pane`,
  `#generate-key`, `#api-key-reveal`, `#api-key-reveal-note`, `#api-key-secret`,
  `#copy-key`, `#api-key-details`, `#api-key-name`, `#api-key-masked`, `#api-key-created`,
  `#api-key-last-used`, `#regenerate-key`, `#revoke-key`, `#board-settings-link`

**Steps**

- [x] Write the failing LiveView test at `test/relay_web/live/board_settings_live_test.exs`:

  ```elixir
  defmodule RelayWeb.BoardSettingsLiveTest do
    use RelayWeb.ConnCase, async: true

    import Phoenix.LiveViewTest

    alias Relay.ApiKeys
    alias Relay.Boards

    describe "when logged out" do
      test "GET /board/settings redirects to the sign-in page", %{conn: conn} do
        assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/board/settings")
      end
    end

    describe "API key pane" do
      setup :register_and_log_in_user

      test "with no key, offers Generate and shows no secret or details", %{conn: conn} do
        {:ok, view, _html} = live(conn, ~p"/board/settings")

        assert has_element?(view, "#generate-key")
        refute has_element?(view, "#api-key-secret")
        refute has_element?(view, "#api-key-details")
      end

      test "generate reveals the full secret once, with copy button and warning", %{conn: conn, user: user} do
        {:ok, view, _html} = live(conn, ~p"/board/settings")

        view |> element("#generate-key") |> render_click()

        secret = revealed_secret(view)
        assert secret =~ ~r/^relay_[0-9a-f]{12}_[0-9a-f]{64}$/
        assert has_element?(view, "#copy-key")
        assert has_element?(view, "#api-key-reveal-note")
        refute has_element?(view, "#generate-key")

        # the revealed token is the real key — it authenticates against this board
        board = Boards.get_or_create_default_board(user)
        assert {:ok, authed_board} = ApiKeys.authenticate(secret)
        assert authed_board.id == board.id
      end

      test "on reload only the masked display shows — never the raw secret", %{conn: conn, user: user} do
        {:ok, view, _html} = live(conn, ~p"/board/settings")
        view |> element("#generate-key") |> render_click()
        secret = revealed_secret(view)

        {:ok, view, _html} = live(conn, ~p"/board/settings")

        refute has_element?(view, "#api-key-secret")
        refute render(view) =~ secret

        key = user |> Boards.get_or_create_default_board() |> ApiKeys.get_key()
        masked = view |> element("#api-key-masked") |> render()
        assert masked =~ key.token_prefix
        assert masked =~ key.last_four
      end

      test "shows name, masked value, created, and last-used; no second Generate", %{conn: conn, user: user} do
        board = Boards.get_or_create_default_board(user)
        {:ok, _created} = ApiKeys.create_key(board, user)

        {:ok, view, _html} = live(conn, ~p"/board/settings")

        assert has_element?(view, "#api-key-name", "Board API key")
        assert has_element?(view, "#api-key-masked")
        assert has_element?(view, "#api-key-created")
        assert has_element?(view, "#api-key-last-used", "Never")
        assert has_element?(view, "#regenerate-key")
        assert has_element?(view, "#revoke-key")
        refute has_element?(view, "#generate-key")
      end

      test "regenerate reveals a new secret once and invalidates the old one", %{conn: conn, user: user} do
        board = Boards.get_or_create_default_board(user)
        {:ok, %{token: old_token}} = ApiKeys.create_key(board, user)

        {:ok, view, _html} = live(conn, ~p"/board/settings")
        view |> element("#regenerate-key") |> render_click()

        new_secret = revealed_secret(view)
        assert new_secret =~ ~r/^relay_[0-9a-f]{12}_[0-9a-f]{64}$/
        refute new_secret == old_token
        assert :error = ApiKeys.authenticate(old_token)
        assert {:ok, _board} = ApiKeys.authenticate(new_secret)

        # reveal is once: a fresh mount shows only the masked display
        {:ok, view, _html} = live(conn, ~p"/board/settings")
        refute has_element?(view, "#api-key-secret")
      end

      test "revoke removes the key and offers Generate again", %{conn: conn, user: user} do
        board = Boards.get_or_create_default_board(user)
        {:ok, %{token: token}} = ApiKeys.create_key(board, user)

        {:ok, view, _html} = live(conn, ~p"/board/settings")
        view |> element("#revoke-key") |> render_click()

        assert has_element?(view, "#generate-key")
        refute has_element?(view, "#api-key-details")
        assert ApiKeys.get_key(board) == nil
        assert :error = ApiKeys.authenticate(token)
      end

      test "the board page links to settings", %{conn: conn} do
        {:ok, view, _html} = live(conn, ~p"/board")

        assert has_element?(view, "#board-settings-link[href='/board/settings']")
      end
    end

    defp revealed_secret(view) do
      view
      |> element("#api-key-secret")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()
    end
  end
  ```

  Run `mix test test/relay_web/live/board_settings_live_test.exs` — it must fail
  (route/module don't exist).

- [x] Add the route in `lib/relay_web/router.ex`, inside the existing authenticated
  live_session (no extra alias — the scope provides `RelayWeb`):

  ```elixir
  live_session :require_authenticated, on_mount: [{RelayWeb.Auth, :require_authenticated}] do
    live "/board", BoardLive
    live "/board/settings", BoardSettingsLive
  end
  ```

- [x] Create `lib/relay_web/live/board_settings_live.ex`:

  ```elixir
  defmodule RelayWeb.BoardSettingsLive do
    @moduledoc """
    Board settings (`/board/settings`) — the first settings surface (MMF 08;
    MMF 12 stage config and MMF 10b sub-lane toggles extend this page).

    Hosts the API key pane: generate / regenerate / revoke the board's single
    key via `Relay.ApiKeys`. The raw secret lives only in the `:revealed_token`
    assign for the mount that created it — shown exactly once, never
    re-retrievable. Authorization is inherent: everything operates on the
    current user's own board.
    """

    use RelayWeb, :live_view

    alias Relay.ApiKeys
    alias Relay.Boards

    @impl true
    def render(assigns) do
      ~H"""
      <Layouts.app flash={@flash} current_scope={@current_scope}>
        <div class="mx-auto max-w-2xl space-y-6">
          <div class="flex items-center gap-2">
            <.link
              navigate={~p"/board"}
              id="back-to-board"
              class="btn btn-ghost btn-sm btn-circle"
              aria-label="Back to board"
            >
              <.icon name="hero-arrow-left" class="size-4" />
            </.link>
            <h1 id="settings-title" class="text-xl font-semibold">Board settings</h1>
          </div>

          <section id="api-key-pane" class="card border border-base-300 bg-base-100">
            <div class="card-body space-y-4">
              <div>
                <h2 class="card-title text-base">API key</h2>
                <p class="text-sm text-base-content/60">
                  Lets external tools (like Claude Code) act on this board. One key per board.
                </p>
              </div>

              <div :if={@revealed_token} id="api-key-reveal" class="space-y-2">
                <div id="api-key-reveal-note" class="alert alert-warning text-sm">
                  <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
                  <span>Copy this key now — you won't be able to see it again.</span>
                </div>
                <div class="join w-full">
                  <code
                    id="api-key-secret"
                    class="join-item flex flex-1 items-center overflow-x-auto border border-base-300 bg-base-200 px-3 py-2 font-mono text-sm"
                  >{@revealed_token}</code>
                  <button
                    id="copy-key"
                    type="button"
                    class="join-item btn btn-primary"
                    phx-hook=".CopyKey"
                    data-target="api-key-secret"
                  >
                    <.icon name="hero-clipboard" class="size-4" /> Copy
                  </button>
                </div>
                <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyKey">
                  export default {
                    mounted() {
                      this.el.addEventListener("click", () => {
                        const target = document.getElementById(this.el.dataset.target)
                        if (target) navigator.clipboard.writeText(target.textContent.trim())
                      })
                    }
                  }
                </script>
              </div>

              <%= if @api_key do %>
                <dl id="api-key-details" class="grid grid-cols-[auto_1fr] gap-x-6 gap-y-1 text-sm">
                  <dt class="text-base-content/60">Name</dt>
                  <dd id="api-key-name">{@api_key.name}</dd>
                  <dt class="text-base-content/60">Key</dt>
                  <dd id="api-key-masked" class="font-mono">{masked(@api_key)}</dd>
                  <dt class="text-base-content/60">Created</dt>
                  <dd id="api-key-created">{format_time(@api_key.inserted_at)}</dd>
                  <dt class="text-base-content/60">Last used</dt>
                  <dd id="api-key-last-used">{last_used(@api_key)}</dd>
                </dl>
                <div class="card-actions">
                  <button
                    id="regenerate-key"
                    class="btn btn-outline btn-sm"
                    phx-click="regenerate_key"
                    data-confirm="Regenerate the key? The current key stops working immediately."
                  >
                    <.icon name="hero-arrow-path" class="size-4" /> Regenerate
                  </button>
                  <button
                    id="revoke-key"
                    class="btn btn-outline btn-error btn-sm"
                    phx-click="revoke_key"
                    data-confirm="Revoke the key? Tools using it will lose access."
                  >
                    <.icon name="hero-trash" class="size-4" /> Revoke
                  </button>
                </div>
              <% else %>
                <div class="card-actions">
                  <button id="generate-key" class="btn btn-primary btn-sm" phx-click="generate_key">
                    <.icon name="hero-key" class="size-4" /> Generate key
                  </button>
                </div>
              <% end %>
            </div>
          </section>
        </div>
      </Layouts.app>
      """
    end

    @impl true
    def mount(_params, _session, socket) do
      board = Boards.get_or_create_default_board(socket.assigns.current_scope.user)

      {:ok,
       socket
       |> assign(:page_title, "Board settings")
       |> assign(:board, board)
       |> assign(:api_key, ApiKeys.get_key(board))
       |> assign(:revealed_token, nil)}
    end

    @impl true
    def handle_event("generate_key", _params, socket) do
      case ApiKeys.create_key(socket.assigns.board, socket.assigns.current_scope.user) do
        {:ok, %{api_key: key, token: token}} ->
          {:noreply, socket |> assign(:api_key, key) |> assign(:revealed_token, token)}

        {:error, :already_exists} ->
          {:noreply,
           socket
           |> put_flash(:error, "This board already has an API key.")
           |> assign(:api_key, ApiKeys.get_key(socket.assigns.board))}
      end
    end

    def handle_event("regenerate_key", _params, socket) do
      {:ok, %{api_key: key, token: token}} = ApiKeys.regenerate(socket.assigns.api_key)
      {:noreply, socket |> assign(:api_key, key) |> assign(:revealed_token, token)}
    end

    def handle_event("revoke_key", _params, socket) do
      {:ok, _key} = ApiKeys.revoke(socket.assigns.api_key)

      {:noreply,
       socket
       |> assign(:api_key, nil)
       |> assign(:revealed_token, nil)
       |> put_flash(:info, "API key revoked.")}
    end

    defp masked(key), do: "relay_#{key.token_prefix}_…#{key.last_four}"

    defp last_used(%{last_used_at: nil}), do: "Never"
    defp last_used(%{last_used_at: at}), do: format_time(at)

    defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%b %d, %Y, %H:%M UTC")
  end
  ```

- [x] Make the page reachable: in `lib/relay_web/live/board_live.ex` (in `render/1`, the
  template currently has the title directly under `<div id="board" ...>`), replace:

  ```heex
  <h1 id="board-title" class="text-xl font-semibold">{@board.name}</h1>
  ```

  with:

  ```heex
  <div class="flex items-center justify-between">
    <h1 id="board-title" class="text-xl font-semibold">{@board.name}</h1>
    <.link
      navigate={~p"/board/settings"}
      id="board-settings-link"
      class="btn btn-ghost btn-sm btn-circle"
      aria-label="Board settings"
    >
      <.icon name="hero-cog-6-tooth" class="size-5" />
    </.link>
  </div>
  ```

- [x] Run `mix test test/relay_web/live/board_settings_live_test.exs` — all green. Run
  `mix test` (full suite — the `board_live` template changed, so its tests must still
  pass). Then `mix precommit` — fix anything it flags before committing.

**Deliverable (independently testable):** an authenticated `/board/settings` page (linked
from the board header via a gear icon) where the owner generates a key and sees the full
`relay_…` secret exactly once (with copy-to-clipboard and a "you won't see it again"
warning); on reload only the masked `relay_<prefix>_…<last4>` display shows alongside
name/created/last-used; Regenerate reveals a new secret once and kills the old one; Revoke
removes the key; Generate is never offered while a key exists. All verified by
`mix test test/relay_web/live/board_settings_live_test.exs`.

**Commit message:**

```
feat(api-keys): /board/settings LiveView with the API key pane (MMF 08)

Generate reveals the raw token exactly once (copy-to-clipboard +
warning); masked display with created/last-used on reload; regenerate
and revoke; settings gear linked from the board header.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vr8Fre7pvjAxbBQsM6SoB7
```

---

## Acceptance criteria coverage (from the spec)

- **Creating a key shows the full secret exactly once, then only a masked display** →
  Task 2 tests "generate reveals the full secret once…" and "on reload only the masked
  display shows…".
- **The key shows name, masked value, created and last-used** → Task 2 test "shows name,
  masked value, created, and last-used…" (last-used starts as "Never"; `authenticate/1`
  bumps it — covered at the context level in Task 1).
- **Regenerate replaces the secret; Revoke disables/removes the key** → Task 1
  `regenerate/1`/`revoke/1` tests + Task 2 "regenerate…"/"revoke…" tests.
- **Tokens are stored hashed (raw secret never re-retrievable)** → Task 1 "stores only a
  SHA-256 hash…" test; Task 2 reload test asserts the raw secret never reappears in the
  rendered page.
- **A second "generate" while a key exists is not offered (single-key invariant)** →
  Task 1 `{:error, :already_exists}` test + DB unique index; Task 2 `refute
  has_element?(view, "#generate-key")` assertions.
