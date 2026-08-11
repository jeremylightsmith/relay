# ADR 0010 — The board serves the scaffold

## Status

Proposed (2026-08-10)

Supersedes the bootstrap decision recorded in RLY-208, which removed the scaffold-over-HTTP
surface from the board server.

## Context

Relay's tooling reached a project through an external **`relay-config`** GitHub repo:
`mix relay.publish_config` wrote the tree, a human committed and pushed it, and `bin/relay init`
pulled `manifest.json` over HTTPS. Three moving parts and two places to forget.

The `.relay/published.json` marker existed only to paper over the gap between "merged here" and
"actually being served" — the board could not truthfully name a version an executor could
download, so a second, hand-maintained number stood in for the real one. `mix precommit` carried
a drift warning for the same reason.

RLY-208 chose that shape deliberately, to keep the board server out of the scaffolding path. In
practice the cost landed elsewhere: every fix to `bin/relay` or a `relay-*` skill needed a
separate publish + push before it reached anyone, and a forgotten publish was invisible until a
card died on it.

Separately, the surface being distributed had shrunk. Once flows became server-side data
(ADR 0006) and `/relay-onboard` owned repo wiring, the only files Relay genuinely owns in a
project are `bin/relay` and four `relay-*` skills — none of which a user ever edits.

## Decision

The Relay app builds and serves those five files itself.

`mix relay.build_scaffold` copies them into `priv/scaffold/` and writes a manifest whose
`version` is **derived** from content — the first 12 hex characters of the sha256 of the sorted
`"<path>:<sha256>"` lines. `GET /api/scaffold` returns that manifest and
`GET /api/scaffold/*path` returns the bytes of any entry in it, both unauthenticated, because
`/relay-setup` runs before a project has a board key.

`bin/relay update` is the one mechanism for getting the files onto disk. Because the five are
Relay-owned and never user-edited, it overwrites unconditionally: no provenance ledger, no
per-file diff prompt. Every item is hashed against the manifest on every run and the work list is
the verdict — a missing *or* edited file is rewritten, and "current" means nothing needs writing.
The recorded version is a record of what was installed, never the trigger: RE185's auto-update
moves `bin/relay`'s bytes without touching it, so gating on it would misreport the steady state.

`bin/relay init`, `mix relay.publish_config`, `.relay/published.json`,
`Relay.Runs.PublishMarker` and the precommit drift check are deleted.
`Relay.Runs.latest_executor_version/0` now reports the `EXECUTOR_VERSION` of the `bin/relay` the
app actually serves.

## Consequences

- **Publishing is coupled to deploying.** A skill fix reaches projects only when the app ships.
  This is the whole trade: accepted in exchange for deleting the publish/marker/drift apparatus
  and making "what can an executor download?" answerable from the running system rather than
  from a marker a human maintains.
- **`latest_executor_version` cannot lie.** The advertised number and the served bytes come from
  the same file.
- **A new unauthenticated public surface.** Mitigated by construction: the glob route serves only
  entries in a static six-item allowlist, and the same files were published openly before.
- **`priv/scaffold/` must be built before `mix release`.** The `Dockerfile`, `mix setup` and the
  `test` alias all run the task; a build that skips it serves a 503 and advertises
  `latest_executor_version: null`.
- **Executors already in the field need one manual cutover.** An executor running a pre-RE304
  `bin/relay` resolves its update URL from `RELAY_CONFIG_URL` / the relay-config raw base, not
  from the board. Once this deploys it keeps polling relay-config, gets `NOTHING_NEWER`, and is
  permanently pinned — silently, because `min_executor_version/0` is unchanged so it still
  claims work, and neither `bin/relay update` nor `/relay-update` exists in that checkout to
  heal it. Each such checkout needs one hand-run:
  `curl -fsSL "$RELAY_URL/api/scaffold/bin/relay" -o bin/relay` (equivalently, one final publish
  to relay-config before retiring it).
- **Rolling back to a project's old tooling means rolling back the app.** There is no
  independent publish channel any more, by design.
- `Relay.Runs.min_executor_version/0` and the 409 `executor_outdated` refusal are unchanged.

## Amendment — `relay.md` joins the set (six files)

The decision above scoped Relay-owned to `bin/relay` and the four `relay-*` skills, reasoning
that flows had become server-side data and `/relay-onboard` owned repo wiring. That reasoning
swept in `relay.md` by association, but it does not hold for that file:

- `relay.md` is **generic**. It is the agent-facing guide to driving a card — the CLI verbs, the
  mental model, the node/outcome contract, the `RELAY_NODE_SCRATCH` rule. Nothing in it is
  repo-specific, so there is nothing for a project to own.
- It describes the executor, so it goes **stale in lockstep** with `bin/relay`. Leaving it
  undistributed meant each project's copy froze at whatever `/relay-onboard` first authored while
  the tooling it documents kept moving — the same silent-drift failure this ADR exists to remove,
  reintroduced one file over.

So `relay.md` is served, and `/relay-onboard` no longer authors one. `.relay/executor.json` stays
outside the set: it holds genuinely per-machine values (`capacity`, `base`, `prepare`), and
overwriting it unconditionally would clobber real configuration.

The Decision section above is left as written — it records what was decided at the time, and
"five" there should be read as superseded by this amendment. Everywhere outside this document the
count is **six**. Nothing else changes: same derived version, same unconditional overwrite, same
manifest shape.

## Alternatives considered

**Keep `relay-config`, automate the publish from CI.** Removes the forgotten-publish failure but
keeps two systems, two histories, and the marker that reconciles them. The marker is the thing
worth deleting.

**Store the scaffold in the database with an admin upload surface.** Decouples publishing from
deploying, at the cost of a new write surface, provenance questions, and a way for the served
scaffold to disagree with the repo that produced it. Explicitly a non-goal.
