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
5. **Announce the two steps people will notice:** signing in once more ([RE480]) and the runner
   update ([RE478]).

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
- [x] Email: nothing to do yet. Prod has no `RESEND_API_KEY`, so mail is off; the sending domain
      is part of [RE480].

## Phases 2–6: cards on the RE board (Backlog)

| Order | Card | Blocked by |
|---|---|---|
| 2a | [RE476 Hamaca landing page: Hammock Driven Development] | none |
| 2b | [RE477 Say Hamaca everywhere a person reads the name] | none |
| 3 | [RE480 Make hamaca.app the main address] | RE476, RE477 |
| 4 | [RE481 Rename the code to Hamaca (modules, app, docs, repo)] | RE476, RE477 |
| 5 | [RE478 Rename the runner to ./hamaca with a compatibility window] | RE481 |
| 5 | [RE479 Mobile app as Hamaca: new bundle IDs, name, icons] | RE480 |
| 6 | [RE482 End the relay → hamaca compatibility window] | RE478 |

Why this order:
- The landing page and UI strings change only what people read, so they go first.
- The host flip waits for them, so the first thing anyone sees at the main address says Hamaca.
- The code rename touches every file, so it runs when the board is quiet. The runner rename
  follows it, so it doesn't fight the module rename.
- The mobile app follows the host flip, so the new app points at hamaca.app from its first build.
- Cleanup waits until every active runner is on `./hamaca`.
