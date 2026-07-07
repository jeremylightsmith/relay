# Plan: MMF 01 — Sign in with Google

**Spec:** `docs/superpowers/specs/2026-07-07-google-login-design.md`

## Goal

Add "Sign in with Google" (Google OAuth only, open signup) so a person can authenticate and be
recognized on return, gating the app. Includes a dev/test-only login bypass so later MMFs, tests,
and the acceptance smoke can authenticate without a real Google round-trip. Post-login destination
is a minimal authenticated stub page ("You're signed in as {name}") with a top-bar avatar and
Sign out — MMF 02 replaces it with the board.

## Architecture

- **`Relay.Accounts`** (new domain context, own Boundary): `User` schema (`users` table),
  `Scope` struct, `upsert_user_from_google/1` (keyed on Google `sub` → `provider_uid`),
  `get_user/1`, `ensure_dev_user!/0`. No web concerns here.
- **`RelayWeb.Auth`** (new module in the existing `RelayWeb` boundary): all Plug/session logic —
  `fetch_current_scope/2` and `require_authenticated/2` plugs, `log_in_user/2`, `log_out_user/1`,
  and `on_mount` hooks (`:mount_current_scope`, `:require_authenticated`) for `live_session`.
- **`RelayWeb.AuthController`**: Ueberauth request/callback phases + `delete` (logout).
- **`RelayWeb.DevLoginController`**: `GET /dev/login`, compiled only when
  `Application.compile_env(:relay, :dev_routes)` is truthy (dev + test, never prod).
- **Routes:** public `GET /` sign-in page (existing `PageController`, repurposed);
  `/auth/:provider` + `/auth/:provider/callback`; `DELETE /logout`; authenticated
  `live_session :require_authenticated` wrapping `live "/home", HomeLive` (the stub).
  `fetch_current_scope` added to the `:browser` pipeline.
- **Session:** plain Phoenix session storing `:user_id`; renewed on login, cleared on logout.

## Tech

Phoenix 1.8 / LiveView 1.1, Ecto + Postgres, `{:ueberauth, "~> 0.10"}` +
`{:ueberauth_google, "~> 0.12"}` (new deps), Boundary (compiler-enforced), ExMachina factories
(test), daisyUI 5 + Tailwind v4 for UI. Toolchain runs through `mise`.

## Global Constraints

1. **Toolchain:** prefix every mix command with `mise exec --` (e.g. `mise exec -- mix test`).
   Postgres must be running locally (dev creds `postgres/postgres`, see `config/dev.exs`).
2. **`mise exec -- mix precommit` is REQUIRED at the end of every task and must pass** before the
   task is considered done. It runs compile (warnings as errors), `deps.unlock --unused`,
   `mix format` (with Styler), `credo --strict`, `sobelow`, `deps.audit`, and the full test suite
   (warnings as errors). Never commit with a failing precommit.
3. **Boundary rules (violations fail compilation):**
   - `Relay.Accounts` gets `use Boundary, deps: [Relay.Repo], exports: [User, Scope]`.
   - `Accounts` and `Accounts.Scope` must be added to `Relay`'s `exports` in `lib/relay.ex`.
   - `RelayWeb.Auth`, `AuthController`, `DevLoginController`, `HomeLive` live in the existing
     `RelayWeb` boundary (no new Boundary declarations for them).
   - `Relay.Accounts.User` is **not** exported through `Relay`, so modules under `lib/relay_web/`
     must never `alias`/reference `Relay.Accounts.User` — access user fields with plain dot access
     (`user.email`). Test files under `test/` are not compiled into boundaries and may reference it.
4. **Google-only, open signup.** No email/password, no other providers, no allowlist, no
   board/org creation (this MMF creates only the `User`).
5. **No hardcoded secrets.** Google client id/secret come only from env vars `GOOGLE_CLIENT_ID` /
   `GOOGLE_CLIENT_SECRET` (read in `config/runtime.exs`; dummy static values in `config/test.exs`).
   Never write real values into any committed file.
6. **Tests must never hit real Google.** Controller tests assign a fake
   `%Ueberauth.Auth{}` / `%Ueberauth.Failure{}` on the conn; the request-phase test only asserts
   the redirect Location, which is never followed.
7. **Keep `Relay.Accounts` free of web concerns** — all Plug/session logic lives in `RelayWeb.Auth`.
8. **Fields set programmatically (`provider`, `provider_uid`) are assigned explicitly on the
   struct, never `cast` from input** (AGENTS.md Ecto rule).
9. Every new module needs a `@moduledoc` (credo `--strict`).
10. Phoenix 1.8 conventions: LiveView templates begin with
    `<Layouts.app flash={@flash} current_scope={@current_scope}>`; prefer daisyUI classes; give key
    elements unique DOM ids and use those ids in tests (`has_element?(view, "#id")`), not raw HTML.
11. Commit each task separately with the commit message given at the end of the task.

---

### Task 1: `Relay.Accounts` context — User, Scope, upsert, dev user, factory

**Files**
- Modify: `mix.exs` (add ueberauth deps)
- Create: `priv/repo/migrations/<timestamp>_create_users.exs` (via `mix ecto.gen.migration`)
- Create: `lib/relay/accounts.ex`
- Create: `lib/relay/accounts/user.ex`
- Create: `lib/relay/accounts/scope.ex`
- Modify: `lib/relay.ex` (Boundary exports)
- Create: `test/support/factory.ex`
- Modify: `test/support/data_case.ex` (import factory)
- Create (test): `test/relay/accounts_test.exs`

**Interfaces**
- Consumes: `Relay.Repo` (existing), `%Ueberauth.Auth{}` / `%Ueberauth.Auth.Info{}` (new deps).
- Produces (later tasks rely on these exact signatures):
  - `Relay.Accounts.upsert_user_from_google(%Ueberauth.Auth{}) :: {:ok, %Relay.Accounts.User{}} | {:error, Ecto.Changeset.t()}`
  - `Relay.Accounts.get_user(id :: integer()) :: %Relay.Accounts.User{} | nil`
  - `Relay.Accounts.ensure_dev_user!() :: %Relay.Accounts.User{}` (email `dev@relay.local`, provider `"dev"`, provider_uid `"dev-user"`)
  - `Relay.Accounts.Scope.for_user(%Relay.Accounts.User{}) :: %Relay.Accounts.Scope{user: user}`; `Scope.for_user(nil) :: nil`
  - `%Relay.Accounts.User{id, email, name, avatar_url, provider, provider_uid}`
  - `Relay.Factory.insert(:user, overrides \\ [])` (ExMachina; defaults: unique email, name `"Test User"`, avatar_url set, provider `"google"`, unique provider_uid)

**Steps**

- [x] Add the ueberauth deps to `mix.exs`. In the `deps` list, insert after `{:bandit, "~> 1.5"},`:

  ```elixir
      # --- Auth: Google OAuth via Ueberauth (MMF 01) ---
      {:ueberauth, "~> 0.10"},
      {:ueberauth_google, "~> 0.12"},
  ```

- [x] Run `mise exec -- mix deps.get` and then `mise exec -- mix compile` (expect: fetches
  `ueberauth`, `ueberauth_google`, `oauth2`; compiles clean).

- [ ] Write the failing test at `test/relay/accounts_test.exs`:

  ```elixir
  defmodule Relay.AccountsTest do
    use Relay.DataCase, async: true

    alias Relay.Accounts
    alias Relay.Accounts.Scope
    alias Relay.Accounts.User

    defp google_auth(attrs) do
      %Ueberauth.Auth{
        provider: :google,
        uid: Map.get(attrs, :uid, "google-uid-123"),
        info: %Ueberauth.Auth.Info{
          email: Map.get(attrs, :email, "ada@example.com"),
          name: Map.get(attrs, :name, "Ada Lovelace"),
          image: Map.get(attrs, :image, "https://example.com/ada.png")
        }
      }
    end

    describe "upsert_user_from_google/1" do
      test "creates a user on first sign-in" do
        assert {:ok, %User{} = user} = Accounts.upsert_user_from_google(google_auth(%{}))
        assert user.email == "ada@example.com"
        assert user.name == "Ada Lovelace"
        assert user.avatar_url == "https://example.com/ada.png"
        assert user.provider == "google"
        assert user.provider_uid == "google-uid-123"
      end

      test "reuses and updates the user on later sign-ins with the same provider_uid" do
        {:ok, user} = Accounts.upsert_user_from_google(google_auth(%{}))

        assert {:ok, updated} =
                 Accounts.upsert_user_from_google(
                   google_auth(%{
                     name: "Ada K. Lovelace",
                     email: "ada@newmail.example",
                     image: "https://example.com/new.png"
                   })
                 )

        assert updated.id == user.id
        assert updated.name == "Ada K. Lovelace"
        assert updated.email == "ada@newmail.example"
        assert updated.avatar_url == "https://example.com/new.png"
        assert Repo.aggregate(User, :count) == 1
      end

      test "enforces email uniqueness across different google accounts" do
        insert(:user, email: "taken@example.com")

        assert {:error, changeset} =
                 Accounts.upsert_user_from_google(
                   google_auth(%{uid: "other-uid", email: "taken@example.com"})
                 )

        assert %{email: ["has already been taken"]} = errors_on(changeset)
      end
    end

    describe "get_user/1" do
      test "returns the user for an id" do
        user = insert(:user)
        assert Accounts.get_user(user.id).id == user.id
      end

      test "returns nil for an unknown id" do
        assert Accounts.get_user(-1) == nil
      end
    end

    describe "ensure_dev_user!/0" do
      test "creates the dev user on first call and reuses it after" do
        user = Accounts.ensure_dev_user!()

        assert user.email == "dev@relay.local"
        assert user.provider == "dev"
        assert user.provider_uid == "dev-user"
        assert Accounts.ensure_dev_user!().id == user.id
        assert Repo.aggregate(User, :count) == 1
      end
    end

    describe "Scope.for_user/1" do
      test "wraps a user" do
        user = insert(:user)
        assert %Scope{user: ^user} = Scope.for_user(user)
      end

      test "returns nil for nil" do
        assert Scope.for_user(nil) == nil
      end
    end
  end
  ```

- [ ] Run `mise exec -- mix test test/relay/accounts_test.exs` — expect FAILURE (compile errors:
  `Relay.Accounts` / `Relay.Factory` undefined).

- [ ] Generate the migration: `mise exec -- mix ecto.gen.migration create_users`, then replace the
  generated file's contents (keep the generated filename/timestamp) with:

  ```elixir
  defmodule Relay.Repo.Migrations.CreateUsers do
    use Ecto.Migration

    def change do
      create table(:users) do
        add :email, :string, null: false
        add :name, :string
        add :avatar_url, :string
        add :provider, :string, null: false
        add :provider_uid, :string, null: false

        timestamps(type: :utc_datetime)
      end

      create unique_index(:users, [:email])
      create unique_index(:users, [:provider_uid])
    end
  end
  ```

- [ ] Create `lib/relay/accounts/user.ex`:

  ```elixir
  defmodule Relay.Accounts.User do
    @moduledoc """
    A person who signed in. Identity is keyed on `provider_uid`
    (Google's stable `sub` claim); `provider` and `provider_uid` are set
    programmatically, never cast from input.
    """

    use Ecto.Schema

    import Ecto.Changeset

    schema "users" do
      field :email, :string
      field :name, :string
      field :avatar_url, :string
      field :provider, :string
      field :provider_uid, :string

      timestamps(type: :utc_datetime)
    end

    @doc "Changeset for profile fields coming from the OAuth provider."
    def changeset(user, attrs) do
      user
      |> cast(attrs, [:email, :name, :avatar_url])
      |> validate_required([:email])
      |> unique_constraint(:email)
      |> unique_constraint(:provider_uid)
    end
  end
  ```

- [ ] Create `lib/relay/accounts/scope.ex`:

  ```elixir
  defmodule Relay.Accounts.Scope do
    @moduledoc """
    The current-user scope handed to LiveViews and controllers as
    `current_scope` (Phoenix 1.8 convention; `<Layouts.app>` expects it).
    `nil` means "not signed in".
    """

    alias Relay.Accounts.User

    defstruct user: nil

    @doc "Builds a scope for a signed-in user; returns nil for nil."
    def for_user(%User{} = user), do: %__MODULE__{user: user}
    def for_user(nil), do: nil
  end
  ```

- [ ] Create `lib/relay/accounts.ex`:

  ```elixir
  defmodule Relay.Accounts do
    @moduledoc """
    The Accounts context: users and the current-user scope.

    Google OAuth is the only real sign-in path (open signup — any Google
    account gets a user). `ensure_dev_user!/0` backs the dev/test-only
    login bypass. Web/session concerns live in `RelayWeb.Auth`, not here.
    """

    use Boundary, deps: [Relay.Repo], exports: [User, Scope]

    alias Relay.Accounts.User
    alias Relay.Repo

    @dev_user_email "dev@relay.local"
    @dev_user_uid "dev-user"

    @doc "Fetches a user by primary key. Returns nil when not found."
    def get_user(id), do: Repo.get(User, id)

    @doc """
    Upserts a user from a Google `%Ueberauth.Auth{}`: looks up by
    `provider_uid` (Google's `sub`), creating on first sign-in and
    refreshing `email`/`name`/`avatar_url` on return visits.
    """
    def upsert_user_from_google(%Ueberauth.Auth{} = auth) do
      provider_uid = to_string(auth.uid)
      attrs = %{email: auth.info.email, name: auth.info.name, avatar_url: auth.info.image}

      case Repo.get_by(User, provider_uid: provider_uid) do
        nil ->
          %User{provider: "google", provider_uid: provider_uid}
          |> User.changeset(attrs)
          |> Repo.insert()

        %User{} = user ->
          user
          |> User.changeset(attrs)
          |> Repo.update()
      end
    end

    @doc """
    Upserts and returns the fixed local dev user (dev/test only login
    bypass — see `GET /dev/login`). Never used in prod.
    """
    def ensure_dev_user! do
      case Repo.get_by(User, provider_uid: @dev_user_uid) do
        nil ->
          %User{provider: "dev", provider_uid: @dev_user_uid}
          |> User.changeset(%{email: @dev_user_email, name: "Dev User"})
          |> Repo.insert!()

        %User{} = user ->
          user
      end
    end
  end
  ```

- [ ] In `lib/relay.ex`, update the Boundary declaration to export the new context:

  ```elixir
    use Boundary, deps: [], exports: [Repo, Mailer, Accounts, Accounts.Scope]
  ```

- [ ] Create `test/support/factory.ex` (ExMachina; opted out of Boundary checks like
  `Relay.DataCase`):

  ```elixir
  defmodule Relay.Factory do
    @moduledoc """
    ExMachina factories for tests. Boundary checks are disabled because
    this is test-only support code that may reach into any context.
    """

    use Boundary, top_level?: true, check: [in: false, out: false]
    use ExMachina.Ecto, repo: Relay.Repo

    def user_factory do
      %Relay.Accounts.User{
        email: sequence(:email, &"user#{&1}@example.com"),
        name: "Test User",
        avatar_url: "https://example.com/avatar.png",
        provider: "google",
        provider_uid: sequence(:provider_uid, &"google-uid-#{&1}")
      }
    end
  end
  ```

- [ ] In `test/support/data_case.ex`, add `import Relay.Factory` to the `using` block (after
  `import Ecto.Query`):

  ```elixir
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Relay.DataCase
      import Relay.Factory
  ```

- [ ] Run `mise exec -- mix test test/relay/accounts_test.exs` — expect ALL PASS.
- [ ] Run `mise exec -- mix ecto.migrate` (applies the migration to the dev DB too).
- [ ] Run `mise exec -- mix precommit` — must pass. Fix any credo/format/boundary findings.
- [ ] Commit everything.

**Deliverable:** `mise exec -- mix test test/relay/accounts_test.exs` green; domain layer complete
and boundary-clean with no web changes.

**Commit message:** `feat: add Relay.Accounts context with Google-backed users`

---

### Task 2: Session plumbing (`RelayWeb.Auth`), gated `/home` stub, ConnCase login helpers

**Files**
- Create: `lib/relay_web/auth.ex`
- Create: `lib/relay_web/live/home_live.ex`
- Modify: `lib/relay_web/router.ex`
- Modify: `test/support/conn_case.ex`
- Create (test): `test/relay_web/auth_test.exs`
- Create (test): `test/relay_web/live/home_live_test.exs`

**Interfaces**
- Consumes (from Task 1): `Relay.Accounts.get_user(id)`, `Relay.Accounts.Scope.for_user(user_or_nil)`,
  `Relay.Factory.insert(:user, overrides)`, `%Relay.Accounts.Scope{user: user}`.
- Produces (later tasks rely on these exact names/behaviors):
  - `RelayWeb.Auth.fetch_current_scope(conn, opts) :: conn` — assigns `:current_scope` (`%Scope{}` or nil) from session key `:user_id`.
  - `RelayWeb.Auth.require_authenticated(conn, opts) :: conn` — halts + redirects to `/` with error flash when no scope.
  - `RelayWeb.Auth.log_in_user(conn, user) :: conn` — renews session, puts `:user_id`, redirects to `/home`.
  - `RelayWeb.Auth.log_out_user(conn) :: conn` — renews + clears session, redirects to `/`.
  - `RelayWeb.Auth.on_mount(:mount_current_scope | :require_authenticated, params, session, socket)`.
  - Route `live "/home", HomeLive` inside `live_session :require_authenticated`; `:browser` pipeline now runs `fetch_current_scope`.
  - `RelayWeb.ConnCase.log_in_user(conn, user \\ nil) :: conn` (nil inserts a factory user) and `RelayWeb.ConnCase.register_and_log_in_user(%{conn: conn}) :: %{conn: conn, user: user}` setup helper.

**Steps**

- [ ] Write the failing plug/session test at `test/relay_web/auth_test.exs`:

  ```elixir
  defmodule RelayWeb.AuthTest do
    use RelayWeb.ConnCase, async: true

    alias Relay.Accounts.Scope
    alias RelayWeb.Auth

    setup %{conn: conn} do
      conn =
        conn
        |> Map.replace!(:secret_key_base, RelayWeb.Endpoint.config(:secret_key_base))
        |> Plug.Test.init_test_session(%{})

      %{conn: conn}
    end

    describe "fetch_current_scope/2" do
      test "assigns the current scope when the session has a user id", %{conn: conn} do
        user = insert(:user)
        conn = conn |> put_session(:user_id, user.id) |> Auth.fetch_current_scope([])

        assert conn.assigns.current_scope.user.id == user.id
      end

      test "assigns nil without a session user id", %{conn: conn} do
        conn = Auth.fetch_current_scope(conn, [])
        assert conn.assigns.current_scope == nil
      end

      test "assigns nil when the user no longer exists", %{conn: conn} do
        conn = conn |> put_session(:user_id, -1) |> Auth.fetch_current_scope([])
        assert conn.assigns.current_scope == nil
      end
    end

    describe "require_authenticated/2" do
      test "halts and redirects to the sign-in page without a current scope", %{conn: conn} do
        conn =
          conn
          |> Phoenix.Controller.fetch_flash()
          |> assign(:current_scope, nil)
          |> Auth.require_authenticated([])

        assert conn.halted
        assert redirected_to(conn) == ~p"/"
      end

      test "passes through with a current scope", %{conn: conn} do
        user = insert(:user)

        conn =
          conn
          |> assign(:current_scope, Scope.for_user(user))
          |> Auth.require_authenticated([])

        refute conn.halted
      end
    end

    describe "log_in_user/2" do
      test "renews the session, stores the user id, and redirects home", %{conn: conn} do
        user = insert(:user)
        conn = conn |> put_session(:stale, "value") |> Auth.log_in_user(user)

        assert get_session(conn, :user_id) == user.id
        refute get_session(conn, :stale)
        assert redirected_to(conn) == ~p"/home"
      end
    end

    describe "log_out_user/1" do
      test "clears the session and redirects to the sign-in page", %{conn: conn} do
        user = insert(:user)
        conn = conn |> put_session(:user_id, user.id) |> Auth.log_out_user()

        refute get_session(conn, :user_id)
        assert redirected_to(conn) == ~p"/"
      end
    end
  end
  ```

- [ ] Write the failing LiveView gate test at `test/relay_web/live/home_live_test.exs`:

  ```elixir
  defmodule RelayWeb.HomeLiveTest do
    use RelayWeb.ConnCase, async: true

    import Phoenix.LiveViewTest

    describe "when logged out" do
      test "GET /home redirects to the sign-in page", %{conn: conn} do
        assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/home")
      end
    end

    describe "when logged in" do
      setup :register_and_log_in_user

      test "shows the signed-in stub with the user's name", %{conn: conn, user: user} do
        {:ok, view, _html} = live(conn, ~p"/home")

        assert has_element?(view, "#home-stub")
        assert render(view) =~ user.name
      end
    end
  end
  ```

- [ ] Run `mise exec -- mix test test/relay_web/auth_test.exs test/relay_web/live/home_live_test.exs`
  — expect FAILURE (`RelayWeb.Auth` undefined, no `/home` route, no ConnCase helpers).

- [ ] Create `lib/relay_web/auth.ex`:

  ```elixir
  defmodule RelayWeb.Auth do
    @moduledoc """
    Session-based authentication plumbing: plugs for the router/controllers
    and `on_mount` hooks for LiveViews. The domain lives in `Relay.Accounts`;
    every Plug/session concern lives here.
    """

    use RelayWeb, :verified_routes

    import Phoenix.Controller
    import Plug.Conn

    alias Relay.Accounts
    alias Relay.Accounts.Scope

    @doc "Plug: assigns `:current_scope` from the session (nil when logged out)."
    def fetch_current_scope(conn, _opts) do
      user_id = get_session(conn, :user_id)
      user = user_id && Accounts.get_user(user_id)
      assign(conn, :current_scope, Scope.for_user(user))
    end

    @doc "Plug: redirects to the sign-in page when there is no current user."
    def require_authenticated(conn, _opts) do
      if conn.assigns[:current_scope] do
        conn
      else
        conn
        |> put_flash(:error, "You must sign in to access this page.")
        |> redirect(to: ~p"/")
        |> halt()
      end
    end

    @doc "Renews the session, stores the user id, and redirects to the app home."
    def log_in_user(conn, user) do
      conn
      |> renew_session()
      |> put_session(:user_id, user.id)
      |> redirect(to: ~p"/home")
    end

    @doc "Clears the session and redirects to the sign-in page."
    def log_out_user(conn) do
      conn
      |> renew_session()
      |> redirect(to: ~p"/")
    end

    @doc """
    `on_mount` hooks for `live_session`:

      * `:mount_current_scope` — assigns `current_scope` (or nil) and continues.
      * `:require_authenticated` — additionally halts with a redirect to the
        sign-in page when there is no signed-in user.
    """
    def on_mount(:mount_current_scope, _params, session, socket) do
      {:cont, mount_current_scope(socket, session)}
    end

    def on_mount(:require_authenticated, _params, session, socket) do
      socket = mount_current_scope(socket, session)

      if socket.assigns.current_scope do
        {:cont, socket}
      else
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You must sign in to access this page.")
          |> Phoenix.LiveView.redirect(to: ~p"/")

        {:halt, socket}
      end
    end

    defp mount_current_scope(socket, session) do
      Phoenix.Component.assign_new(socket, :current_scope, fn ->
        user = session["user_id"] && Accounts.get_user(session["user_id"])
        Scope.for_user(user)
      end)
    end

    defp renew_session(conn) do
      conn
      |> configure_session(renew: true)
      |> clear_session()
    end
  end
  ```

- [ ] Create `lib/relay_web/live/home_live.ex` (minimal stub; Task 4 adds the top-bar UI in the
  layout, MMF 02 replaces this page with the board):

  ```elixir
  defmodule RelayWeb.HomeLive do
    @moduledoc """
    Post-login stub home ("You're signed in as {name}"). Replaced by the
    board in MMF 02.
    """

    use RelayWeb, :live_view

    @impl true
    def render(assigns) do
      ~H"""
      <Layouts.app flash={@flash} current_scope={@current_scope}>
        <div id="home-stub" class="text-center space-y-2 py-12">
          <h1 class="text-xl font-semibold">
            You're signed in as {@current_scope.user.name || @current_scope.user.email}
          </h1>
          <p class="text-base-content/70">The board arrives in the next release.</p>
        </div>
      </Layouts.app>
      """
    end

    @impl true
    def mount(_params, _session, socket) do
      {:ok, socket}
    end
  end
  ```

- [ ] Replace `lib/relay_web/router.ex` with (only changes vs. current file: the
  `import RelayWeb.Auth`, the `plug :fetch_current_scope` at the end of `:browser`, and the
  `live_session` block; CSP, dev block, etc. stay identical):

  ```elixir
  defmodule RelayWeb.Router do
    use RelayWeb, :router

    import PhoenixStorybook.Router
    import RelayWeb.Auth

    @content_security_policy "default-src 'self'; " <>
                               "script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; " <>
                               "style-src 'self' 'unsafe-inline'; " <>
                               "img-src 'self' data: blob:; " <>
                               "font-src 'self'; " <>
                               "connect-src 'self' blob: ws: wss:; " <>
                               "base-uri 'self'; " <>
                               "form-action 'self'; " <>
                               "frame-ancestors 'self';"

    pipeline :browser do
      plug :accepts, ["html"]
      plug :fetch_session
      plug :fetch_live_flash
      plug :put_root_layout, html: {RelayWeb.Layouts, :root}
      plug :protect_from_forgery
      plug :put_secure_browser_headers, %{"content-security-policy" => @content_security_policy}
      plug :fetch_current_scope
    end

    pipeline :api do
      plug :accepts, ["json"]
    end

    scope "/", RelayWeb do
      pipe_through :browser

      get "/", PageController, :home

      live_session :require_authenticated, on_mount: [{RelayWeb.Auth, :require_authenticated}] do
        live "/home", HomeLive
      end
    end

    # Other scopes may use custom stacks.
    # scope "/api", RelayWeb do
    #   pipe_through :api
    # end

    # Enable LiveDashboard and Swoosh mailbox preview in development
    if Application.compile_env(:relay, :dev_routes) do
      # If you want to use the LiveDashboard in production, you should put
      # it behind authentication and allow only admins to access it.
      # If your application does not have an admins-only section yet,
      # you can use Plug.BasicAuth to set up some basic authentication
      # as long as you are also using SSL (which you should anyway).
      import Phoenix.LiveDashboard.Router

      scope "/dev" do
        pipe_through :browser

        live_dashboard "/dashboard", metrics: RelayWeb.Telemetry
        forward "/mailbox", Plug.Swoosh.MailboxPreview
      end

      scope "/" do
        storybook_assets()
      end

      scope "/", RelayWeb do
        pipe_through :browser
        live_storybook "/storybook", backend_module: RelayWeb.Storybook
      end
    end
  end
  ```

- [ ] Replace `test/support/conn_case.ex` with:

  ```elixir
  defmodule RelayWeb.ConnCase do
    @moduledoc """
    This module defines the test case to be used by
    tests that require setting up a connection.

    Such tests rely on `Phoenix.ConnTest` and also
    import other functionality to make it easier
    to build common data structures and query the data layer.

    Finally, if the test case interacts with the database,
    we enable the SQL sandbox, so changes done to the database
    are reverted at the end of every test. If you are using
    PostgreSQL, you can even run database tests asynchronously
    by setting `use RelayWeb.ConnCase, async: true`, although
    this option is not recommended for other databases.
    """

    use ExUnit.CaseTemplate

    using do
      quote do
        use RelayWeb, :verified_routes

        import Phoenix.ConnTest
        import Plug.Conn
        import Relay.Factory
        import RelayWeb.ConnCase

        # The default endpoint for testing
        @endpoint RelayWeb.Endpoint

        # Import conveniences for testing with connections
      end
    end

    setup tags do
      Relay.DataCase.setup_sandbox(tags)
      {:ok, conn: Phoenix.ConnTest.build_conn()}
    end

    @doc """
    Logs the given user (or a freshly inserted factory user) into the
    test session, so requests hit routes as an authenticated user
    without touching real Google.
    """
    def log_in_user(conn, user \\ nil) do
      user = user || Relay.Factory.insert(:user)
      Plug.Test.init_test_session(conn, user_id: user.id)
    end

    @doc """
    Setup helper that inserts a user and logs it in:

        setup :register_and_log_in_user
    """
    def register_and_log_in_user(%{conn: conn}) do
      user = Relay.Factory.insert(:user)
      %{conn: log_in_user(conn, user), user: user}
    end
  end
  ```

- [ ] Run `mise exec -- mix test test/relay_web/auth_test.exs test/relay_web/live/home_live_test.exs`
  — expect ALL PASS.
- [ ] Run `mise exec -- mix precommit` — must pass (existing `PageControllerTest` still passes:
  `GET /` is unchanged in this task and `fetch_current_scope` is a no-op without a session user).
- [ ] Commit everything.

**Deliverable:** `/home` exists and is gated (logged-out access redirects to `/`); tests can
authenticate via `log_in_user`/`register_and_log_in_user` without Google.

**Commit message:** `feat: add session auth plumbing and gated home stub`

---

### Task 3: Google OAuth controller, logout, dev login, and config

**Files**
- Create: `lib/relay_web/controllers/auth_controller.ex`
- Create: `lib/relay_web/controllers/dev_login_controller.ex`
- Modify: `lib/relay_web/router.ex` (auth + logout + dev login routes)
- Modify: `config/config.exs` (ueberauth provider)
- Modify: `config/test.exs` (dummy Google creds + `dev_routes: true`)
- Modify: `config/runtime.exs` (env-based Google creds)
- Modify: `.envrc.local.example` (document the two vars)
- Create (test): `test/relay_web/controllers/auth_controller_test.exs`
- Create (test): `test/relay_web/controllers/dev_login_controller_test.exs`

**Interfaces**
- Consumes (from earlier tasks): `Relay.Accounts.upsert_user_from_google(%Ueberauth.Auth{})`,
  `Relay.Accounts.ensure_dev_user!()`, `RelayWeb.Auth.log_in_user(conn, user)` (redirects to
  `/home`), `RelayWeb.Auth.log_out_user(conn)` (redirects to `/`), `RelayWeb.ConnCase.log_in_user/2`,
  `Relay.Factory.insert(:user, overrides)`.
- Produces:
  - Routes: `GET /auth/:provider` (request), `GET /auth/:provider/callback`, `DELETE /logout`,
    and `GET /dev/login` (compiled only when `:dev_routes`; available in dev AND test).
  - `RelayWeb.AuthController` actions `request/2`, `callback/2`, `delete/2`.
  - `RelayWeb.DevLoginController.create/2`.
  - Task 4's sign-in page links to `~p"/auth/google"`; its layout links to `~p"/logout"`.

**Steps**

- [ ] Configure the Ueberauth provider. In `config/config.exs`, add just above the final
  `import_config "#{config_env()}.exs"` line:

  ```elixir
  # Google OAuth (Ueberauth). Only the provider list lives here; the client
  # id/secret come from the environment at runtime (see config/runtime.exs)
  # or static dummies in config/test.exs — never hardcode secrets.
  config :ueberauth, Ueberauth,
    providers: [
      google: {Ueberauth.Strategy.Google, [default_scope: "email profile"]}
    ]
  ```

- [ ] In `config/test.exs`, append at the end of the file:

  ```elixir
  # Dummy Google OAuth credentials — tests never contact real Google; the
  # request-phase redirect is asserted but never followed.
  config :ueberauth, Ueberauth.Strategy.Google.OAuth,
    client_id: "test-google-client-id",
    client_secret: "test-google-client-secret"

  # Compile dev-only routes (GET /dev/login, LiveDashboard, storybook) into
  # the test router so tests and the acceptance smoke can authenticate
  # without real Google. Never enabled in prod.
  config :relay, dev_routes: true
  ```

- [ ] In `config/runtime.exs`, add after the
  `config :relay, RelayWeb.Endpoint, http: [port: ...]` line and before `if config_env() == :prod do`:

  ```elixir
  # Google OAuth credentials. Dev reads these from .envrc.local (direnv);
  # prod from `fly secrets set`. Test uses static dummies from
  # config/test.exs, which this must not override with nils.
  if config_env() != :test do
    config :ueberauth, Ueberauth.Strategy.Google.OAuth,
      client_id: System.get_env("GOOGLE_CLIENT_ID"),
      client_secret: System.get_env("GOOGLE_CLIENT_SECRET")
  end
  ```

- [ ] In `.envrc.local.example`, replace the line `# export SOME_API_KEY=...` with:

  ```
  # Google OAuth (MMF 01). Create an OAuth client in Google Cloud Console with
  # authorized redirect URIs:
  #   http://localhost:4003/auth/google/callback
  #   https://relayboard.fly.dev/auth/google/callback
  # In prod, set the same two values with `fly secrets set`.
  # export GOOGLE_CLIENT_ID=...
  # export GOOGLE_CLIENT_SECRET=...
  ```

- [ ] Write the failing controller test at `test/relay_web/controllers/auth_controller_test.exs`:

  ```elixir
  defmodule RelayWeb.AuthControllerTest do
    use RelayWeb.ConnCase, async: true

    alias Relay.Accounts.User
    alias Relay.Repo

    defp google_auth do
      %Ueberauth.Auth{
        provider: :google,
        uid: "google-uid-123",
        info: %Ueberauth.Auth.Info{
          email: "ada@example.com",
          name: "Ada Lovelace",
          image: "https://example.com/ada.png"
        }
      }
    end

    describe "GET /auth/google (request phase)" do
      test "redirects to Google's consent screen", %{conn: conn} do
        conn = get(conn, ~p"/auth/google")
        assert redirected_to(conn) =~ "accounts.google.com"
      end
    end

    describe "GET /auth/google/callback" do
      test "with a successful auth upserts the user, starts a session, and redirects home",
           %{conn: conn} do
        conn =
          conn
          |> assign(:ueberauth_auth, google_auth())
          |> get(~p"/auth/google/callback")

        user = Repo.get_by!(User, provider_uid: "google-uid-123")
        assert user.email == "ada@example.com"
        assert get_session(conn, :user_id) == user.id
        assert redirected_to(conn) == ~p"/home"
        assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Signed in"
      end

      test "reuses the existing user on a repeat sign-in", %{conn: conn} do
        existing = insert(:user, provider_uid: "google-uid-123", email: "ada@example.com")

        conn =
          conn
          |> assign(:ueberauth_auth, google_auth())
          |> get(~p"/auth/google/callback")

        assert get_session(conn, :user_id) == existing.id
        assert Repo.aggregate(User, :count) == 1
      end

      test "with a failure flashes an error and redirects to sign-in", %{conn: conn} do
        conn =
          conn
          |> assign(:ueberauth_failure, %Ueberauth.Failure{errors: []})
          |> get(~p"/auth/google/callback")

        assert redirected_to(conn) == ~p"/"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "failed"
        refute get_session(conn, :user_id)
        assert Repo.aggregate(User, :count) == 0
      end
    end

    describe "DELETE /logout" do
      test "clears the session and redirects to the sign-in page", %{conn: conn} do
        user = insert(:user)

        conn =
          conn
          |> log_in_user(user)
          |> delete(~p"/logout")

        refute get_session(conn, :user_id)
        assert redirected_to(conn) == ~p"/"
      end
    end
  end
  ```

- [ ] Write the failing dev-login test at `test/relay_web/controllers/dev_login_controller_test.exs`:

  ```elixir
  defmodule RelayWeb.DevLoginControllerTest do
    use RelayWeb.ConnCase, async: true

    alias Relay.Accounts.User
    alias Relay.Repo

    test "GET /dev/login signs in the dev user and redirects home", %{conn: conn} do
      conn = get(conn, ~p"/dev/login")

      user = Repo.get_by!(User, provider: "dev")
      assert user.email == "dev@relay.local"
      assert get_session(conn, :user_id) == user.id
      assert redirected_to(conn) == ~p"/home"
    end

    test "GET /dev/login is idempotent across sign-ins", %{conn: conn} do
      get(conn, ~p"/dev/login")
      get(conn, ~p"/dev/login")

      assert Repo.aggregate(User, :count) == 1
    end
  end
  ```

- [ ] Run `mise exec -- mix test test/relay_web/controllers/auth_controller_test.exs test/relay_web/controllers/dev_login_controller_test.exs`
  — expect FAILURE (no such routes/controllers).

- [ ] Create `lib/relay_web/controllers/auth_controller.ex`. Clause order matters: the
  `ueberauth_auth` clause must come first (in tests both assigns can be present because the
  Ueberauth plug also runs):

  ```elixir
  defmodule RelayWeb.AuthController do
    @moduledoc """
    Google OAuth via Ueberauth: `request` redirects to Google (handled by
    the Ueberauth plug), `callback` upserts the user and starts the
    session, `delete` logs out.
    """

    use RelayWeb, :controller

    plug Ueberauth

    alias Relay.Accounts
    alias RelayWeb.Auth

    @doc """
    Request phase. The Ueberauth plug redirects to Google before this
    action runs; reaching it means the provider was not recognized.
    """
    def request(conn, _params) do
      conn
      |> put_flash(:error, "Authentication provider not supported.")
      |> redirect(to: ~p"/")
    end

    def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
      case Accounts.upsert_user_from_google(auth) do
        {:ok, user} ->
          conn
          |> put_flash(:info, "Signed in as #{user.email}")
          |> Auth.log_in_user(user)

        {:error, _changeset} ->
          conn
          |> put_flash(:error, "Google sign-in failed. Please try again.")
          |> redirect(to: ~p"/")
      end
    end

    def callback(%{assigns: %{ueberauth_failure: _failure}} = conn, _params) do
      conn
      |> put_flash(:error, "Google sign-in failed. Please try again.")
      |> redirect(to: ~p"/")
    end

    def delete(conn, _params) do
      conn
      |> put_flash(:info, "Signed out.")
      |> Auth.log_out_user()
    end
  end
  ```

- [ ] Create `lib/relay_web/controllers/dev_login_controller.ex`:

  ```elixir
  defmodule RelayWeb.DevLoginController do
    @moduledoc """
    Dev/test-only login bypass (`GET /dev/login`): signs in a fixed local
    user without a Google round-trip. The route is compiled only when
    `:dev_routes` is set (dev + test) — never in prod.
    """

    use RelayWeb, :controller

    alias Relay.Accounts
    alias RelayWeb.Auth

    def create(conn, _params) do
      user = Accounts.ensure_dev_user!()

      conn
      |> put_flash(:info, "Signed in as #{user.email}")
      |> Auth.log_in_user(user)
    end
  end
  ```

- [ ] Update `lib/relay_web/router.ex`. Make exactly these three edits:

  1. In the main `scope "/", RelayWeb do` block, add `delete "/logout", AuthController, :delete`
     after the `get "/", PageController, :home` line:

  ```elixir
    scope "/", RelayWeb do
      pipe_through :browser

      get "/", PageController, :home
      delete "/logout", AuthController, :delete

      live_session :require_authenticated, on_mount: [{RelayWeb.Auth, :require_authenticated}] do
        live "/home", HomeLive
      end
    end
  ```

  2. Directly below that scope (before the commented-out `# scope "/api"` block), add:

  ```elixir
    scope "/auth", RelayWeb do
      pipe_through :browser

      get "/:provider", AuthController, :request
      get "/:provider/callback", AuthController, :callback
    end
  ```

  3. Inside the existing `if Application.compile_env(:relay, :dev_routes) do` block, add this
     scope (after the existing `scope "/dev" do ... end` block):

  ```elixir
      # Dev/test-only login bypass — the acceptance smoke and local
      # development sign in here instead of real Google.
      scope "/dev", RelayWeb do
        pipe_through :browser

        get "/login", DevLoginController, :create
      end
  ```

- [ ] Run `mise exec -- mix test test/relay_web/controllers/auth_controller_test.exs test/relay_web/controllers/dev_login_controller_test.exs`
  — expect ALL PASS.
- [ ] Run `mise exec -- mix test` — full suite green (enabling `dev_routes` in test compiles the
  LiveDashboard/storybook routes into the test router; if anything in that block fails to compile,
  fix the compile error rather than reverting the config).
- [ ] Run `mise exec -- mix precommit` — must pass.
- [ ] Commit everything.

**Deliverable:** Completing Google OAuth (simulated via fake `ueberauth_auth` assign) creates or
reuses a `User`, starts a session, and redirects to `/home`; OAuth failure flashes an error and
returns to sign-in; `DELETE /logout` ends the session; `GET /dev/login` signs in the dev user in
dev/test.

**Commit message:** `feat: add Google OAuth controller, logout, and dev login`

---

### Task 4: Sign-in page and signed-in top bar (avatar + Sign out)

**Files**
- Modify: `lib/relay_web/controllers/page_controller.ex`
- Modify: `lib/relay_web/controllers/page_html/home.html.heex` (full replace)
- Modify: `lib/relay_web/components/layouts.ex` (`app/1` header + `initials/1` helper)
- Modify: `lib/relay_web/router.ex` (CSP: allow Google avatar images)
- Modify (test): `test/relay_web/controllers/page_controller_test.exs` (full replace)
- Modify (test): `test/relay_web/live/home_live_test.exs` (add top-bar + sign-out-flow tests)

**Interfaces**
- Consumes: route `~p"/auth/google"` (Task 3), route `~p"/logout"` (Task 3), route `~p"/home"`
  (Task 2), `conn.assigns.current_scope` from the `:browser` pipeline (Task 2),
  `RelayWeb.ConnCase.log_in_user/2` + `register_and_log_in_user/1` (Task 2),
  `Relay.Factory.insert(:user, overrides)` (Task 1).
- Produces: final MMF 01 UI. Key DOM ids downstream tests/smokes may rely on:
  `#google-signin` (sign-in button on `/`), `#user-avatar` (top bar), `#sign-out` (top bar),
  `#home-stub` (stub page).

**Steps**

- [ ] Rewrite `test/relay_web/controllers/page_controller_test.exs` (failing first):

  ```elixir
  defmodule RelayWeb.PageControllerTest do
    use RelayWeb.ConnCase, async: true

    describe "GET / when logged out" do
      test "renders the sign-in page with a Google button", %{conn: conn} do
        conn = get(conn, ~p"/")
        html = html_response(conn, 200)

        assert html =~ "Sign in with Google"
        assert html =~ "id=\"google-signin\""
        assert html =~ ~p"/auth/google"
      end
    end

    describe "GET / when logged in" do
      setup :register_and_log_in_user

      test "redirects to the app home", %{conn: conn} do
        conn = get(conn, ~p"/")
        assert redirected_to(conn) == ~p"/home"
      end
    end
  end
  ```

- [ ] Append these describe blocks to `test/relay_web/live/home_live_test.exs` (inside the module,
  after the existing `describe "when logged in"` block):

  ```elixir
    describe "top bar" do
      test "shows the avatar image and a sign out link", %{conn: conn} do
        user = insert(:user, avatar_url: "https://example.com/me.png")
        {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/home")

        assert has_element?(view, "#user-avatar img")
        assert has_element?(view, "#sign-out")
      end

      test "falls back to initials when the user has no avatar image", %{conn: conn} do
        user = insert(:user, avatar_url: nil, name: "Ada Lovelace")
        {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/home")

        refute has_element?(view, "#user-avatar img")
        assert has_element?(view, "#user-avatar", "AL")
      end
    end

    describe "signing out" do
      test "after sign out, the home route requires signing in again", %{conn: conn} do
        user = insert(:user)
        conn = conn |> log_in_user(user) |> delete(~p"/logout")

        assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/home")
      end
    end
  ```

- [ ] Run `mise exec -- mix test test/relay_web/controllers/page_controller_test.exs test/relay_web/live/home_live_test.exs`
  — expect FAILURE (old boilerplate page, no avatar/sign-out in layout).

- [ ] Replace `lib/relay_web/controllers/page_controller.ex` with:

  ```elixir
  defmodule RelayWeb.PageController do
    @moduledoc """
    Public sign-in page. Signed-in users are sent straight to the app home.
    """

    use RelayWeb, :controller

    def home(conn, _params) do
      if conn.assigns.current_scope do
        redirect(conn, to: ~p"/home")
      else
        render(conn, :home)
      end
    end
  end
  ```

- [ ] Replace the entire contents of `lib/relay_web/controllers/page_html/home.html.heex` with the
  minimal sign-in page (MMF 02 owns the real landing):

  ```heex
  <Layouts.flash_group flash={@flash} />
  <main class="min-h-screen flex items-center justify-center px-4">
    <div class="card bg-base-200 w-full max-w-sm shadow-md">
      <div class="card-body items-center text-center gap-6">
        <div>
          <h1 class="text-2xl font-semibold">Relay</h1>
          <p class="mt-2 text-base-content/70">Sign in to continue</p>
        </div>
        <a href={~p"/auth/google"} id="google-signin" class="btn btn-primary w-full">
          <svg viewBox="0 0 48 48" class="size-5" aria-hidden="true">
            <path
              fill="#EA4335"
              d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"
            />
            <path
              fill="#4285F4"
              d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"
            />
            <path
              fill="#FBBC05"
              d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"
            />
            <path
              fill="#34A853"
              d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"
            />
          </svg>
          Sign in with Google
        </a>
      </div>
    </div>
  </main>
  ```

- [ ] In `lib/relay_web/components/layouts.ex`, replace the entire `def app(assigns) do ... end`
  function (keep the existing `attr`/`slot` declarations above it, and keep `flash_group`/
  `theme_toggle` unchanged) with:

  ```elixir
    def app(assigns) do
      ~H"""
      <header class="navbar px-4 sm:px-6 lg:px-8">
        <div class="flex-1">
          <a href={~p"/"} class="flex w-fit items-center gap-2">
            <img src={~p"/images/logo.svg"} width="36" alt="Relay" />
            <span class="text-sm font-semibold">Relay</span>
          </a>
        </div>
        <div class="flex-none">
          <ul class="flex px-1 space-x-4 items-center">
            <li>
              <.theme_toggle />
            </li>
            <%= if @current_scope do %>
              <li>
                <%= if @current_scope.user.avatar_url do %>
                  <div id="user-avatar" class="avatar" title={@current_scope.user.email}>
                    <div class="w-8 rounded-full">
                      <img
                        src={@current_scope.user.avatar_url}
                        alt={@current_scope.user.name || @current_scope.user.email}
                        referrerpolicy="no-referrer"
                      />
                    </div>
                  </div>
                <% else %>
                  <div
                    id="user-avatar"
                    class="avatar avatar-placeholder"
                    title={@current_scope.user.email}
                  >
                    <div class="bg-primary text-primary-content w-8 rounded-full">
                      <span class="text-xs">{initials(@current_scope.user)}</span>
                    </div>
                  </div>
                <% end %>
              </li>
              <li>
                <.link href={~p"/logout"} method="delete" id="sign-out" class="btn btn-ghost btn-sm">
                  Sign out
                </.link>
              </li>
            <% end %>
          </ul>
        </div>
      </header>

      <main class="px-4 py-20 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-2xl space-y-4">
          {render_slot(@inner_block)}
        </div>
      </main>

      <.flash_group flash={@flash} />
      """
    end

    # Initials for the avatar fallback, from the user's name (or email
    # when the name is missing). Plain dot access on purpose: Accounts.User
    # is not exported through the Relay boundary to the web layer.
    defp initials(user) do
      (user.name || user.email)
      |> String.split(~r/[\s@._-]+/, trim: true)
      |> Enum.take(2)
      |> Enum.map_join("", &String.first/1)
      |> String.upcase()
    end
  ```

- [ ] In `lib/relay_web/router.ex`, update the CSP `img-src` directive so Google-hosted avatars
  render (they are served from `*.googleusercontent.com`). Change the line

  ```elixir
                               "img-src 'self' data: blob:; " <>
  ```

  to

  ```elixir
                               "img-src 'self' data: blob: https://*.googleusercontent.com; " <>
  ```

- [ ] Run `mise exec -- mix test test/relay_web/controllers/page_controller_test.exs test/relay_web/live/home_live_test.exs`
  — expect ALL PASS.
- [ ] Manual smoke (dev): `mise exec -- mix phx.server`, visit `http://localhost:4003/` (sign-in
  page renders with the Google button), visit `http://localhost:4003/dev/login` (lands on `/home`
  as Dev User with initials avatar), click "Sign out" (back on `/`), visit
  `http://localhost:4003/home` directly (redirected to `/` with the sign-in flash). Stop the server.
- [ ] Run `mise exec -- mix precommit` — must pass.
- [ ] Commit everything.

**Deliverable:** Full MMF 01 flow works end-to-end: `/` shows Sign in with Google (or redirects a
signed-in user to `/home`); `/home` shows "You're signed in as {name}" with a top-bar avatar
(image or initials) and a working Sign out; signed-out users are always bounced back to sign-in.

**Commit message:** `feat: add sign-in page and signed-in top bar`

---

## Spec coverage / acceptance criteria map

- **Visiting an app route while logged out redirects to sign-in** → Task 2
  (`HomeLiveTest` "GET /home redirects to the sign-in page"; `AuthTest` `require_authenticated`).
- **Completing Google OAuth creates (or reuses) a `User` and starts a session** → Task 1
  (`AccountsTest` upsert create/reuse) + Task 3 (`AuthControllerTest` callback success/reuse:
  session set, redirect to `/home`; failure path flashes + redirects).
- **Top bar shows avatar/initials; "Sign out" ends the session** → Task 4 (`HomeLiveTest`
  "top bar" tests) + Task 3 (`AuthControllerTest` DELETE /logout clears session).
- **Returning after sign-out requires signing in again** → Task 3 (logout clears session) +
  Task 4 (`HomeLiveTest` "signing out" flow test) + Task 2 (logged-out gate).
- **Dev login (spec "Dev login" section)** → Task 1 (`ensure_dev_user!/0`), Task 3
  (`GET /dev/login` behind `:dev_routes`, enabled in test), Task 2 (ConnCase `log_in_user/1-2`,
  `register_and_log_in_user`).
- **Config & secrets** → Task 3 (env-based creds in `runtime.exs`, dummies in `test.exs`,
  `.envrc.local.example` documents `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET` + redirect URIs).
  External prerequisite for real Google sign-in (user action, not in this plan): create the Google
  OAuth client and register the two redirect URIs.
- **Boundary** → Task 1 (`Relay.Accounts` boundary + `Relay` exports); web modules stay in
  `RelayWeb` (Tasks 2–4).
