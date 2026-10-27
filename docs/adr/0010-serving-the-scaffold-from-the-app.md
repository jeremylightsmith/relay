# ADR 0010 — The board serves the scaffold

## Status

Accepted

## Context

A project that uses Hamaca needs a few files Hamaca owns, not the project: the runner
(`./hamaca`), the agent guide (`hamaca.md`) and the `hamaca-*` skills. They change whenever
Hamaca does, and a runner that falls behind the board either misbehaves or is refused work
(409 `runner_outdated`). So the files have to reach every project quickly, the board has to be
able to say truthfully which version is current, and installing or refreshing them has to work
before the project has a board key.

Flows are server-side data (ADR 0006) and every agent and repo-specific instruction belongs to
the project, so the set of files Hamaca must distribute is small and nobody is meant to edit it.
`hamaca.md` belongs in the set: it is generic (the CLI verbs, the node/outcome contract, the
`HAMACA_NODE_SCRATCH` rule, nothing repo-specific) and it goes stale in lockstep with the runner
it documents. `.hamaca/runner.json` does not: it holds per-project and per-machine values
(`capacity`, `base`, `prepare`, `skill_dir`, `pointer_file`).

The product is mid-rename from Relay, so runners installed as `./relay` must keep updating
during the compatibility window.

## Decision

**The Hamaca app builds and serves the scaffold itself, and `./hamaca update` is the one way it
gets onto disk.**

- **Built from the repo at deploy time.** `mix hamaca.build_scaffold` copies the sources into
  `priv/scaffold/<layout>/` with a `manifest.json` per layout. Each layout's `version` is
  derived from content: the first 12 hex characters of the sha256 of the sorted
  `"<path>:<sha256>"` lines. Nobody maintains a version number.
- **Served unauthenticated.** `GET /api/scaffold` returns a layout's manifest and
  `GET /api/scaffold/*path` the bytes of one entry in it. The install script and `update` run
  before a project has a board key. The glob route serves only entries in that layout's static
  allowlist (`Hamaca.Scaffold.items/1`).
- **Two layouts from one source, for the rename window.** The `layout` query param picks one of
  `Hamaca.Scaffold.layouts/0`; anything else is 400 `unknown_layout`.
  - `?layout=hamaca`: `hamaca`, `hamaca.md`, the three `.claude/skills/hamaca-{doctor,onboard,update}/SKILL.md`,
    plus the compatibility items: the `relay` shim (it runs the `./hamaca` beside it) and three
    thin `relay-*` alias skills.
  - No param (legacy), what every installed `./relay` runner asks for: `relay` (the full
    runner, same bytes as `hamaca`), `relay.md` and the three `relay-*` skills, generated from
    the Hamaca sources by `Hamaca.Scaffold.to_legacy_names/1`.
- **The served runner knows its board.** The committed runner has a placeholder
  `BOARD_URL = ""` line, and the board bakes its configured URL (`HamacaWeb.Endpoint.url/0`,
  never the request's `Host`) into the copy it serves, so a project needs no `HAMACA_URL`. The
  manifest describes the served bytes: the runner item's `sha256` and `bytes` are the baked
  copy's, and `unbaked_sha256` is the placeholder copy's. The version is derived from the
  unbaked shas, so one build has one version on every board. `HAMACA_URL` overrides the baked
  value, and `update` and auto-update keep a project's baked value.
- **`./hamaca update` overwrites unconditionally.** Because these files are Hamaca's and never
  user-edited, there is no provenance ledger and no per-file prompt. Every item is hashed against
  the manifest on every run, and the work list is the verdict: a missing or edited file is
  rewritten, and "current" means nothing needs writing. `.hamaca/scaffold.json` records what was
  installed but never triggers anything, because auto-update moves the runner's bytes without
  touching it.
- **Skills land in the project's skill dir.** The manifest always uses the canonical
  `.claude/skills/` (`Hamaca.Scaffold.skill_dir/0`). The runner maps those items to the
  `skill_dir` recorded in `.hamaca/runner.json` (Codex uses `.agents/skills`) and points the
  `pointer_file` (default `CLAUDE.md`) at `hamaca.md`. `./hamaca update --skill-dir DIR
  --pointer-file FILE` switches an existing project.
- **The install goes through the same path.** The board's install command
  (`curl -fsSL <board>/b/<slug>/install | sh`) downloads only `./hamaca`, runs
  `./hamaca update --starter-only` to write the user-owned starter files, then `./hamaca update`,
  which installs everything else and verifies every body against the manifest. A failed install
  is recovered by running it again.
- **The board's advertised runner version is the served one.**
  `Hamaca.Runs.latest_runner_version/0` reads `RUNNER_VERSION` from the runner the app serves.

The details (manifest shape, hashing, the rename migration `update` performs, auto-update) are in
[`docs/architecture/runner.md`](../architecture/runner.md#bootstrap-surface-re304-adr-0010).

## Consequences

- **Publishing is coupled to deploying.** A fix to the runner or a skill reaches projects only
  when the app ships, and rolling a project's tooling back means rolling back the app. That is
  the trade for having no separate publish step to forget.
- **`latest_runner_version` can't drift from what's served.** The advertised number and the
  served bytes come from the same file.
- **A public, unauthenticated surface.** It serves only allowlisted files that are open source
  anyway, and checks the layout and path against static lists before touching the filesystem.
- **`priv/scaffold/` must be built.** `mix setup`, the `test` alias and the `Dockerfile` (before
  `mix release`) run `mix hamaca.build_scaffold`. A build that skips it answers 503 and
  advertises `latest_runner_version: null`.
- **`update` refuses to apply in the Hamaca app repo without `--force`.** There the scaffold
  files are the source, and the deployed copy is behind any branch that changes them, so applying
  would silently revert work in progress. `--check` is always allowed.
- **The scaffold ships no agents and no flows.** Every agent is the project's own, and flows
  live on the board.
- **A skill is a single `SKILL.md`.** The allowlist names files, so a reference file beside a
  served skill would never reach a project.
- **The compatibility items go when the window closes.** Removing the legacy layout, the shim
  and the `relay-*` aliases is a change to `Hamaca.Scaffold`'s layout table and to this ADR.
- `Hamaca.Runs.min_runner_version/0` and the 409 `runner_outdated` refusal are independent of
  this decision.

## Alternatives considered

**An external config repo with a publish step (automated from CI or not).** Two systems, two
histories, and a hand-maintained marker to say which version is actually published. A forgotten
publish is invisible until a card fails on it.

**Store the scaffold in the database with an admin upload surface.** Decouples publishing from
deploying, at the cost of a new write surface, provenance questions, and a served scaffold that
can disagree with the repo that produced it.
