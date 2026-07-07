# MMF 01 — Sign in with Google — Design Spec

**Date:** 2026-07-07  **MMF:** [`docs/mmfs/01-google-login.md`](../../mmfs/01-google-login.md)
**Status:** Approved (brainstorm) → ready for `/write-plan`
**Shared files:** none (first feature; introduces `Relay.Accounts` + `RelayWeb.Auth`)

## Overview

Add "Sign in with Google" (Google OAuth only) so a person can authenticate and be recognized
on return, gating the app. Chosen approach: `ueberauth_google` + a lightweight custom session
and a `Relay.Accounts` context with a `Scope`, mirroring the conventions already in the repo.
This is the front door — the board (MMF 02) and everything else sit behind it.

**Decision — open signup.** Any Google account may sign in and get a Relay account (no
allowlist). An allowlist can be added later without reworking this design.

## Out of scope (later MMFs)

- Email/password or any non-Google provider.
- Access allowlist / domain restriction.
- Board auto-creation on first login — MMF 02 (this MMF creates only the `User`).
- Organizations / teams / roles — MMF 17.

## Data model

New context **`Relay.Accounts`** (own `Boundary`, exported from `Relay`).

`Relay.Accounts.User`:
- `email` :string, required, unique
- `name` :string
- `avatar_url` :string
- `provider` :string (`"google"`)
- `provider_uid` :string — Google `sub`, required, **unique** (the stable identity key)
- timestamps

Migration: `users` table with unique indexes on `provider_uid` and `email`.

**Login upsert:** `Accounts.upsert_user_from_google(auth)` looks up by `provider_uid`;
creates if absent, else updates `name`/`avatar_url`/`email`. Fields set programmatically
(`provider`, `provider_uid`) are assigned explicitly, never `cast` from user input.

## Auth / session

- **`Relay.Accounts.Scope`** — struct wrapping the current user (`%Scope{user: %User{}}`),
  built via `Scope.for_user(user)`. This is what LiveViews/controllers read as `current_scope`
  (Phoenix 1.8 `<Layouts.app>` expects it).
- **`RelayWeb.Auth`** (in the `RelayWeb` boundary):
  - `fetch_current_scope/2` plug — loads user id from session → `Accounts.get_user/1` →
    assigns `current_scope` (nil if none).
  - `require_authenticated/2` plug — redirects to the sign-in page if no current user.
  - `log_in_user/2` — renews session, stores `user_id`, redirects.
  - `log_out_user/1` — clears session.
  - `on_mount` hooks: `:mount_current_scope` and `:require_authenticated` for `live_session`.

## OAuth flow

- Deps: `{:ueberauth, "~> 0.10"}`, `{:ueberauth_google, "~> 0.12"}`.
- Config: `ueberauth` providers `google: {Ueberauth.Strategy.Google, [default_scope: "email profile"]}`;
  Google client id/secret from env.
- **`RelayWeb.AuthController`**:
  - `request/2` — delegated to Ueberauth (redirects to Google). (Ueberauth plug handles it.)
  - `callback/2` on `%{assigns: %{ueberauth_auth: auth}}` → `upsert_user_from_google` →
    `Auth.log_in_user` → redirect to post-login destination; flash "Signed in".
  - `callback/2` on `%{assigns: %{ueberauth_failure: _}}` → flash error → redirect to sign-in.
  - `delete/2` (logout) → `Auth.log_out_user` → redirect to sign-in.

## Routes & UI

- Public: `GET /` → sign-in page (a `PageController`/LiveView) with a "Sign in with Google"
  button linking to `/auth/google`. Signed-in users hitting `/` are redirected to the app home.
- Ueberauth: `scope "/auth", RelayWeb do pipe_through :browser; get "/:provider", AuthController, :request; get "/:provider/callback", AuthController, :callback end`, plus `delete "/logout", AuthController, :delete`.
- Authenticated `live_session :require_authenticated, on_mount: [{RelayWeb.Auth, :require_authenticated}]`
  wrapping app routes.
- **Post-login stub:** a minimal authenticated page ("You're signed in as {name}") with a
  top-bar avatar + "Sign out". This is replaced by the board in MMF 02.
- `fetch_current_scope` added to the `:browser` pipeline.

## Config & secrets

- `config/runtime.exs` (prod) + `config/dev.exs` read `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`.
- `.envrc.local.example` documents the two vars; real values in `.envrc.local` (dev) and
  `fly secrets set` (prod).
- **External prerequisite (user):** create a Google OAuth client and register redirect URIs
  `http://localhost:4003/auth/google/callback` and
  `https://relayboard.fly.dev/auth/google/callback`.

## Boundary

- `Relay.Accounts` → `use Boundary, deps: [Relay.Repo], exports: [User, Scope]`.
- Add `Accounts`, `Accounts.Scope` to `Relay`'s `exports` in `lib/relay.ex`.
- `RelayWeb.Auth`, `AuthController` live in the existing `RelayWeb` boundary (deps `[Relay]`).

## Testing

- **Accounts:** `upsert_user_from_google/1` creates on first call, reuses/updates on second
  (same `provider_uid`); email uniqueness enforced. ExMachina `User` factory.
- **AuthController:** callback test assigns a fake `conn.assigns.ueberauth_auth` (no real
  Google call) → asserts user created + session set + redirect; failure assign → redirect +
  flash. Logout clears session.
- **Auth plugs:** `require_authenticated` redirects when logged out; passes through with a
  current scope.
- **LiveView:** a gated route redirects to sign-in when unauthenticated (`Phoenix.LiveViewTest`).

## Acceptance criteria (from the MMF)

- [ ] Visiting an app route while logged out redirects to sign-in.
- [ ] Completing Google OAuth creates (or reuses) a `User` and starts a session.
- [ ] The top bar shows the signed-in user's avatar/initials; "Sign out" ends the session.
- [ ] Returning after sign-out requires signing in again.

## Notes for planning

- Keep `Accounts` free of web concerns; all Plug/session logic lives in `RelayWeb.Auth`.
- The sign-in page and stub home are intentionally minimal — MMF 02 owns the real landing.
