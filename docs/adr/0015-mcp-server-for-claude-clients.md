# ADR 0015 — MCP server for Claude clients

## Status

Accepted

## Context

People want to ask Claude about their boards from wherever they already talk to it: "what's
going on with relay?", "anything need me?". Claude reaches outside tools through MCP servers.
claude.ai, Claude Desktop, the Claude mobile apps and Claude Code all accept a **remote**
connector: a URL that speaks MCP over streamable HTTP and signs the user in with OAuth 2.1.
Only Desktop and Claude Code can also run a **local** stdio server, and only after an install
step on each machine.

Hamaca already has two machine-facing APIs, and neither fits:

- The **board-key `/api`** is the agent's surface. It authenticates one board's key and acts as
  the agent. A Claude conversation acts for a person across all of that person's boards, and
  handing a person's chat a board key would make human requests look like agent work.
- **`/api/all`** is the native app's surface ([ADR 0005](0005-mobile-app-scope-and-architecture.md)).
  It is human-authed, but it is shaped around the app's decision surfaces (approve, reject,
  answer), and it uses a `relayu_` user token that the app gets from its own sign-in. A Claude
  client can't do that sign-in. It needs standard OAuth discovery and dynamic client
  registration.

The app has **no per-IP rate limiter** and no OAuth or rate-limit library.

## Decision

Hamaca hosts **one remote MCP server** at `/mcp`. It is the same for every Claude client.

- **Transport: streamable HTTP in stateless JSON mode.** `POST /mcp` takes one JSON-RPC message
  and answers with JSON. There is no SSE stream and no `Mcp-Session-Id`, so any node can serve
  any request and there is no session state to keep. `GET /mcp` is 405.
- **Auth: OAuth 2.1 with dynamic client registration**, hand-rolled in `Hamaca.Connections`
  and `HamacaWeb.OAuthController` with no new dependency. Discovery is RFC 9728
  (`/.well-known/oauth-protected-resource`, plus its `/mcp`-suffixed alias) and RFC 8414
  (`/.well-known/oauth-authorization-server`). Clients register at `POST /oauth/register`
  (RFC 7591) as public clients with no secret. They prove possession with PKCE S256 only. The
  person approves once on a consent screen (`GET /oauth/authorize`). The code and refresh token
  are exchanged at `POST /oauth/token`. Tokens are hashed `relaym_` bearers, distinct from
  `relayu_` user tokens and `relay_` board keys.
- **It acts as the signed-in person.** Tools call the same domain functions `/api/all` uses.
  It never uses or mints a board key. Membership is the only access rule, and a board the
  person can't see is indistinguishable from a missing one.
- **Scope is fixed.** Every connection can read every board the person is a member of,
  including boards joined later. There is no per-board or per-permission choice. The consent
  screen renders what a connection can and can't do from `Connections.capabilities/1`, the one
  definition. A connection can never approve, reject, answer or move a card. Those decisions
  stay with the person in Hamaca.
- **Registration is bounded by payload caps** (`Connections.registration_limits/0`: the number
  and length of redirect URIs and the length of the client name). Redirect URIs must be
  `https://` or loopback `http://`, with no fragment, and they match exactly at authorize time.
- The new public scopes are `/mcp`, `/oauth/*` and `/.well-known/*`. Nothing is added to the
  board-key `/api` or to `/api/all`.

How the endpoints behave is described in [`docs/architecture/domain.md`](../architecture/domain.md)
(Connections) and [`docs/architecture/runtime.md`](../architecture/runtime.md) (Hosts).

## Consequences

- One URL works in every Claude client, with no install step. The person adds
  `https://<host>/mcp` as a custom connector and approves once.
- We own an OAuth authorization server. Its security rests on code we keep: exact
  `redirect_uri` matching before any redirect, single-use codes that revoke the grant's tokens
  when replayed, hashed tokens, and refresh rotation. A spec change in MCP's auth profile is
  ours to follow.
- The consent page must widen the CSP's `form-action` to the client's redirect origin and the
  Google sign-in origin (`HamacaWeb.ContentSecurityPolicy.header/1`). Browsers enforce
  `form-action` on every redirect that follows a form submit, so the default policy would
  silently block Allow and Cancel (which land on the client) and "Not you?" or an
  expired-session Allow / Cancel (which go through `/auth/google` to Google sign-in).
- `/oauth/token` and `/oauth/register` stay out of `ApiLogger` (token params carry codes and
  refresh tokens) and out of `:accepts` (clients send `*/*`, form bodies or no `Accept`).
- Stateless JSON mode rules out server-initiated messages (progress, sampling, notifications).
  Adding them later means adding SSE and session state.
- Without a rate limiter, anyone can register clients. Each registration is small and capped,
  but rows accumulate.

## Alternatives considered

**A local stdio server** (an npm or `./hamaca` subcommand). It works only in Desktop and Claude
Code, needs an install on every machine, and leaves claude.ai and mobile out.

**A personal access token pasted into the connector.** It is simpler to build, but claude.ai's
custom connectors expect OAuth discovery, and a long-lived pasted token can't be scoped to a
client or revoked per client.

**Reusing `/api/all` or the board-key `/api`.** `/api/all` is ADR 0005's native decision surface
and its sign-in is the app's own. The board-key API acts as the agent on one board. Either would
blur who is acting.

**An OAuth library.** None fits MCP's public-client, dynamic-registration, PKCE-only profile
without bringing far more than we use. The hand-rolled surface is a few hundred lines with tests.

## Open questions

- Registered clients that never complete an authorization accumulate in `oauth_clients`. Do we
  sweep unused rows after a while, and if so, how long is a while?
