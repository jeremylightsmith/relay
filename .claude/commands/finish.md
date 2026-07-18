---
description: Complete a development branch — verify, then merge / PR / keep / discard.
---

Complete the current branch's work.

1. **Verify (tests):** run `mix precommit`. If it fails, stop and report — do not offer options.
2. **Verify (eyes) — for any UI/behavior change.** `mix precommit` and the Code flow's own
   `precommit` → `final_review` → `smoke` → `acceptance` nodes check behavior and structure,
   **not pixels.** Before merging UI work: run the app, drive it
   to each state the change touches, screenshot every state, and **compare against the matching
   `docs/designs/*.html` artboard** (most MMFs are ports of `index.html`, `pipeline.html`,
   `client.html`, `contract.html`, `live_session.html`, `invoicing.html` — the design is the
   spec). Send the screenshots to the user. Log in via `GET /dev/login` (dev-only
   `Accounts.ensure_dev_coach!`) and drive with Playwright (chromium headless, ~1440 viewport)
   on `:4000`; assert key elements via locators, not raw HTML.
   - **Restart the dev server first if this branch added a `mix.exs` dep.** Phoenix hot-reloads
     `.ex` files but **not** new deps, so a stale server makes new-dep code fail silently in the
     browser while tests pass (this bit us on the `:money` dep). `lsof -ti :4000 | xargs kill`,
     then `MIX_ENV=dev mix phx.server`; wait with
     `curl --retry 20 --retry-connrefused --retry-delay 1 http://localhost:4000/` before driving.
3. **Detect** base branch (`git merge-base HEAD main`) and whether a draft PR already
   exists (`gh pr view`).
4. **Present exactly these options** (concise, no extra prose):
   1. Merge back to <base> locally (then delete the branch)
   2. Push & create / promote the Pull Request
   3. Keep the branch as-is
   4. Discard the work (require typed "discard" confirmation)
5. **Execute** the chosen option. For merge: checkout base, merge, re-run `mix precommit`
   on the result, then delete the feature branch. Never discard without typed confirmation.
   - **Option 2 (push / create / promote PR) — rebase onto `origin/main` first, before any
     push.** `git fetch origin main`; if `origin/main` advanced
     (`git rev-list HEAD..origin/main` is non-empty), `git rebase origin/main` and resolve any
     conflicts **preserving both intents** (understand the code; don't blindly pick a side),
     then **re-run `mix precommit`** on the rebased result. If conflicts can't be safely
     resolved or `mix precommit` can't be made green, `git rebase --abort` and STOP with a
     report — do NOT push a guessed resolution. Because the rebase rewrote history, the push
     depends on whether a PR already exists: if one does, the push MUST be
     `git push --force-with-lease` (a plain push would be rejected and force-with-lease is the
     deliberate, safe form); a first-time push is a normal `git push -u`. **Local merge-back
     (option 1) is unaffected — do NOT rebase for option 1.**
   - **If this branch shipped a roadmap MMF, archive it as part of finishing:** `git mv` its
     `docs/roadmap/*.md` into `docs/roadmap/done/`, move its row to the **## Done** table in
     `docs/roadmap/index.md`, and repoint any spec back-links to `done/`.
