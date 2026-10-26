# Relay → Hamaca: rename roadmap

Decided 2026-10-25: the product is **Hamaca** (hamaca.app). Finalists were Hamaca and Cardwall
(cardwall.dev); Cardwall lost because "card wall" is the generic agile term (and a Tuleap feature
name), so it can't be searched or owned. Hamaka lost because it drops the real-word story and its
.dev is taken. Brand and story: [`marketing/brandscript.md`](marketing/brandscript.md), assets:
[`brand/`](brand/README.md).

Two scope decisions (2026-10-25):
- **Ubiquitous language:** the code is renamed too (`Hamaca`, `HamacaWeb`, `:hamaca`), not only
  the UI.
- **New mobile app IDs:** only one person uses the app, so iOS and Android ship as new apps under
  Hamaca bundle IDs instead of keeping the Relay ones.

## Rules that keep this low-disruption

1. **Outside first, inside second.** People see the new name before the code changes under them.
2. **Add, then switch, then remove.** Anything in a user's repo, shell or bookmark (`./relay`,
   `RELAY_*`, `.relay/`, `relay-*` skills, relayboard.fly.dev) keeps working through a
   compatibility window.
3. **relayboard.fly.dev answers forever.** Installed runners, `.envrc` files and links point at it.
4. **Not renamed:** the Fly app `relayboard` (renaming means a new Fly app and moving the database)
   and card keys (RE-, RLY-), which are user data.
5. **Announce the step people will notice:** the runner update ([RE478 Rename the runner to
   ./hamaca with a compatibility window]).

## Phase 0: lock it in, done 2026-10-25

- [x] hamaca.app registered; Porkbun DNS → Fly; certificates for hamaca.app and www issued.
- [x] USPTO knockout search: the only live HAMACA mark is class 22 (hammocks). Classes 9 and 42
      are clear. Filing is [RE461 Trademark the Hamaca name].
- [ ] hamaca.dev ($8.75 at Porkbun, free as of 2026-10-25).
- [ ] Handles: GitHub org (`hamaca` is taken), X/Bluesky, npm scope. Needs the owner to create the
      accounts.

## Phase 1: hamaca.app works as a second address, done 2026-10-25

- [x] `PHX_EXTRA_HOSTS` deployed; LiveView websocket from `https://hamaca.app` returns 101, a
      foreign origin still gets 403.
- [x] Google OAuth (project `relay-501716`): hamaca.app JS origin, and
      `https://hamaca.app/auth/google/callback` + www as redirect URIs.
- [x] Email: nothing to do yet. Prod has no `RESEND_API_KEY`, so mail is off. The sending domain
      waits until mail is turned on (see Phase 3).

## Phase 3: hamaca.app is the main address, done 2026-10-26

[RE480 Make hamaca.app the main address]

- [x] `PHX_HOST` = hamaca.app, so the absolute URLs the app builds name hamaca.app.
- [x] Browser pages on the old hosts (relayboard.fly.dev, www.hamaca.app) answer 301 to the same
      path on hamaca.app.
- [x] `/api`, install scripts, webhooks, OAuth callbacks and attachments keep answering on every
      host, so installed runners, old app builds, Stripe and in-flight sign-ins keep working.
- [x] Announcement dropped. Only a couple of people use the board.
- [ ] When mail is turned on: add hamaca.app as the Resend sending domain, put its SPF, DKIM and
      DMARC records in Porkbun DNS, and set `MAIL_FROM=…@hamaca.app`.

## Phases 2–6: cards on the RE board (Backlog)

| Order | Card | Blocked by |
|---|---|---|
| 2a | [RE476 Hamaca landing page: Hammock Driven Development] | none |
| 2b | [RE477 Say Hamaca everywhere a person reads the name] | none |
| 3 | [RE480 Make hamaca.app the main address] (done, see Phase 3) | RE476, RE477 |
| 4 | [RE481 Rename the code to Hamaca (modules, app, docs, repo)], done 2026-10-26 | RE476, RE477 |
| 5 | [RE478 Rename the runner to ./hamaca with a compatibility window], done | RE481 |
| 5 | [RE479 Mobile app as Hamaca: new bundle IDs, name, icons] | RE480 |
| 6 | [RE482 End the relay → hamaca compatibility window] | RE478 |

The GitHub repo rename was **dropped** from RE481: the repo stays `jeremylightsmith/relay`, so
remotes, CI and the GitHub URLs in the docs keep that name.

Why this order:
- The landing page and UI strings change only what people read, so they go first.
- The host flip waits for them, so the first thing anyone sees at the main address says Hamaca.
- The code rename touches every file, so it runs when the board is quiet. The runner rename
  follows it, so it doesn't fight the module rename.
- The mobile app follows the host flip, so the new app points at hamaca.app from its first build.
- Cleanup waits until every active runner is on `./hamaca`.

## RE482 scope: ending the compatibility window

[RE478 Rename the runner to ./hamaca with a compatibility window] moved everything the runner puts
in a repo to the Hamaca names and left the old names working. [RE482 End the relay → hamaca
compatibility window] removes what it left behind, once every active runner is on `./hamaca`:
- Rewrite existing boards' flow data to the Hamaca names: `$RELAY_NODE_SCRATCH`, `./relay` and
  the `/relay-*` skill names in node prompts and commands. RE478 rewrote no flow data.
- Rename the machine-level paths: `~/.relay/locks`, the runner's cache and state dirs, and
  `.relay-retained`. Rename the `{relay}` flow placeholder.
- Remove the `./relay` shim, the `relay-*` alias skills, the legacy scaffold layout (the default
  when `/api/scaffold` gets no `layout` param), and the `RELAY_*` env var fallbacks.

## RE481 residual names

After [RE481 Rename the code to Hamaca], every line printed by
`grep -rnE "\bRelay\b|RelayWeb|:relay\b|relay_web|_relay_key" lib test config mix.exs` is one of
these, on purpose. Anything else it prints is a missed rename.

**Bundle IDs, owned by [RE479 Mobile app as Hamaca: new bundle IDs, name, icons]:**
- `config/config.exs` — `"com.jeremylightsmith.Relay"`, the Apple client id an iOS identity
  token must carry as `aud`.
- `test/hamaca/config_test.exs:7` and `test/support/apple_token_fixtures.ex:67` — the same id,
  asserted and signed into the test tokens.

**Design artboard file names** — `docs/designs/Relay *.dc.html` are real file names (the Claude
Design project's), so a reference to one keeps the name until the artboards are renamed:
- `lib/hamaca/story_map.ex`, `lib/hamaca/talk.ex`, `lib/hamaca_web/components/*.ex`
  (`core_components`, `run_components`, `story_map_components`, `talk_components`,
  `flow_editor_components`, `flow_graph_components`, `flow_metrics_components`),
  `lib/hamaca_web/live/*.ex` (`board_live`, `board_runners_live`, `board_settings_live`,
  `boards_live`, `flow_editor_live`, `flow_metrics_live`), `lib/hamaca_web/flow_layout.ex`,
  `lib/hamaca_web/story_map_filter.ex`, `lib/hamaca_web/story_map_grid.ex` — comments of the
  form `Relay <Artboard>.dc.html` and `Relay Card Detail v5 · …` (`core_components.ex:45`).
- `test/hamaca/docs_designs_test.exs:6` (opens `Relay Docs.dc.html` / `Relay API Reference.dc.html`)
  and the same artboard-name pattern in test names and comments under `test/hamaca_web/`
  (`core_components_test`, `story_map_*_test`, `board_settings_*_test`, `board_live_*_test`,
  `boards_live_*_test`, `board_runners_live_test`, `flow_*_test`, `talk_components_test`,
  `code_block_copy_hook_test`), including `board_settings_live_test.exs:224` and
  `board_live_tag_test.exs:25` ("the Relay Board artboard").

**Guards that the old name is gone** — they must keep saying `Relay` to mean anything:
- `test/hamaca_web/brand_copy_test.exs` (whole file) — the RE477 scanner for "Relay" in rendered
  copy, its fixtures and its module-reference skip (`alias Relay.Cards`).
- `test/hamaca_web/controllers/page_controller_test.exs` — `refute … "Relay"` on the landing,
  pricing, terms and privacy pages, and the test names that say so.
- `test/hamaca_web/endpoint_session_test.exs:15` — `refute` a `_relay_key` cookie is set.
- `test/hamaca_web/components/layouts_test.exs:75` (`"Relay is updating"`) and
  `test/hamaca_web/live/board_drawer_activity_test.exs:111` (`"Relay AI"`).

**Docs the current-state rename leaves alone** (the current-state docs task of RE481 renamed
`priv/docs/` and `docs/architecture/` and flipped their guards to `Hamaca`):
- `test/hamaca_web/controllers/docs_controller_test.exs` — `"How Relay itself cut over"` and
  the test name and comment around it: the closing history note of
  `docs/runbooks/flow-cutover.md`, which tells how Relay cut over its own flows. Also the
  `refute … Relay` prose guards.

**Test data:** `test/hamaca_web/components/template_picker_components_test.exs` — the copy
source board is named "Relay" (the RE board). Its search test types `"ac"` to match only "Acme";
"Hamaca" contains "ac", so renaming the board would break the test, not the code.
