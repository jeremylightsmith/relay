# MMF 01 — Sign in with Google
**Milestone:** ⭐ MVP   **Depends on:** —
**Design:** top-bar avatar (`Relay Board.dc.html`)   **Size:** ~1 loop

## Value
A person can sign in to Relay with their Google account and is recognized on return. This is
the front door — nothing else is reachable without it.

## In scope
- Google OAuth via `ueberauth` + `ueberauth_google` ("Sign in with Google" only).
- `User` schema (email, name, avatar_url, google_sub) + upsert on login.
- Session: log in, persist current user, log out.
- `current_scope`/current-user plug + `require_authenticated` on app routes; unauthenticated
  users are redirected to a sign-in page.
- A minimal sign-in page and a top-bar user avatar/menu with "Sign out".

## Out of scope
- Any other identity provider (email/password, SSO) — Google only for now.
- Teams/invites/roles — MMF 17.

## Acceptance criteria
- [ ] Visiting an app route while logged out redirects to sign-in.
- [ ] Completing Google OAuth creates (or reuses) a `User` and starts a session.
- [ ] The top bar shows the signed-in user's avatar/initials; "Sign out" ends the session.
- [ ] Returning after sign-out requires signing in again.

## Notes
- Client id/secret via env (`GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET`); wire `.envrc.local`
  and Fly secrets. Add an `Accounts` context (its own `Boundary`, exported from `Relay`).
