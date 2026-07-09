# Plan — RLY-25: Better relay logging (prominent card-switch banner)

## Goal
Make each card switch in the `bin/relay` **runner** log visually unmistakable: a fixed-width
`#####` banner printed immediately before a card's work begins, showing ref, title, stage,
mode (`fresh`/`resume`), and the done target. One new `banner()` helper + one call site in
`work()`. The existing terse `✓ … pushed to …` marker stays as-is (already symmetric with the
new banner). Nothing else in `bin/relay` changes.

## Architecture
`bin/relay` is a single, dependency-free Python 3 script (REST-API CLI + board runner). All
runner feed output goes through one helper, `log(msg)`, which prints `[relay] {msg}`. We add a
sibling helper `banner(lines)` that reuses `log()` so every banner line keeps the `[relay] `
prefix and stays greppable/interleavable with the streamed claude feed. The only behavioural
change is in `work()`, where the single card-switch `log(...)` line becomes a `banner([...])`
call carrying the same information, one field per line.

The runner has no existing Python tests, so this plan also stands up a minimal, stdlib-only
`unittest` harness (`bin/test_relay.py`) that loads `bin/relay` by file path (it has no `.py`
extension and only runs `main()` under `__main__`, so importing it is side-effect-free). Tests
exercise `banner()` directly and `work()` in **DRY mode** — in DRY mode `work()` prints the
banner then loops its steps and returns *before* any network/API call (see `bin/relay:368-371`),
so it is fully testable offline.

## Tech
- Python 3, standard library only (`unittest`, `importlib.util`, `io`, `contextlib`). No new deps.
- Existing Elixir app is untouched.

## Global Constraints (from the spec — apply to every task)
- **Scope is tight:** only the **runner** log output in `bin/relay`. No API, no web UI, no
  CLI-command output changes. Do **not** touch `print_card`, `cmd_board`, or any CLI-command
  rendering.
- **No terminal color / ANSI.** Plain ASCII only (logs are often redirected to files/CI).
- **Fixed banner width — 63 `#`.** No terminal-width detection; no config knob for width or char.
- **No new dependencies.** Still pure-stdlib Python, single runner file.
- **Non-runner CLI commands must stay byte-for-byte unchanged** (`relay card`, `relay board`, …).
- **Verification for this plan runs the Python tests explicitly** with `python3 bin/test_relay.py`
  (the Elixir `mix precommit` suite does not cover Python). `mix precommit` must still pass
  (it will — no Elixir files change), but the *behavioural* gate here is `python3 bin/test_relay.py`.

---

## Task 1: Add `banner()` helper, wire it into `work()`, with a stdlib test harness

**Files**
- Create: `bin/test_relay.py` (stdlib `unittest`; loads `bin/relay` by path)
- Modify: `bin/relay` (add `banner()` after `log()`; replace the card-switch `log(...)` line in `work()`)

**Interfaces**
- **Consumes** (existing in `bin/relay`):
  - `log(msg: str) -> None` — prints `[relay] {msg}` with `flush=True`.
  - `work(card: dict, entry: dict, mode: str) -> None` — the runner's per-card driver; `entry`
    has keys `stage`, `from`, `done`, `action`; `mode` is `"fresh"` or `"resume"`. In DRY mode
    it prints the card-switch line, runs each step via `run_step`, and returns before any API call.
  - Module global `DRY: bool` (default `False`) — gates all side effects.
- **Produces:**
  - `banner(lines: list[str]) -> None` — prints, each via `log()`: a blank line, a 63-wide `#`
    rule, one `## {line}` per element of `lines`, then a closing 63-wide `#` rule.

### Steps

- [x] **Write the failing test harness + `banner` unit tests.** Create `bin/test_relay.py`
  with exactly this content:

  ```python
  #!/usr/bin/env python3
  """Unit tests for the bin/relay runner's card-switch log formatting.

  bin/relay has no .py extension and only runs main() under __main__, so we load it by
  file path as a module and exercise its pure log helpers (banner) plus the DRY-mode
  work() path, which prints the card-switch banner then returns before any API call.

  Run: python3 bin/test_relay.py
  """
  import contextlib
  import importlib.util
  import io
  import os
  import unittest

  RELAY_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "relay")
  _spec = importlib.util.spec_from_file_location("relay_runner", RELAY_PATH)
  relay = importlib.util.module_from_spec(_spec)
  _spec.loader.exec_module(relay)

  RULE = "[relay] " + "#" * 63


  def capture(fn, *args, **kwargs):
      out = io.StringIO()
      with contextlib.redirect_stdout(out):
          fn(*args, **kwargs)
      return out.getvalue()


  class BannerTest(unittest.TestCase):
      def test_banner_wraps_lines_in_hash_rule(self):
          text = capture(relay.banner, ["→ RLY-25  better relay logging",
                                        "Spec (fresh) — then Spec:Review"])
          self.assertEqual(text.splitlines(), [
              "[relay] ",
              RULE,
              "[relay] ## → RLY-25  better relay logging",
              "[relay] ## Spec (fresh) — then Spec:Review",
              RULE,
          ])

      def test_banner_rule_is_63_hashes(self):
          text = capture(relay.banner, ["x"])
          self.assertIn(RULE, text.splitlines())
          self.assertNotIn("[relay] " + "#" * 64, text.splitlines())


  class WorkBannerTest(unittest.TestCase):
      CARD = {"ref": "RLY-25", "title": "better relay logging"}
      ENTRY = {"stage": "Spec", "from": "Spec · Ready", "done": "Spec:Review",
               "action": [{"shell": "echo hi"}]}

      def setUp(self):
          relay.DRY = True
          self.addCleanup(setattr, relay, "DRY", False)

      def test_work_prints_card_switch_banner_fresh(self):
          lines = capture(relay.work, self.CARD, self.ENTRY, "fresh").splitlines()
          self.assertIn("[relay] ## → RLY-25  better relay logging", lines)
          self.assertIn("[relay] ## Spec (fresh) — then Spec:Review", lines)
          self.assertIn(RULE, lines)

      def test_work_banner_shows_resume_mode(self):
          lines = capture(relay.work, self.CARD, self.ENTRY, "resume").splitlines()
          self.assertIn("[relay] ## Spec (resume) — then Spec:Review", lines)


  if __name__ == "__main__":
      unittest.main()
  ```

- [x] **Run the tests, expect failure.** `python3 bin/test_relay.py` — `BannerTest` fails with
  `AttributeError: module 'relay_runner' has no attribute 'banner'`, and `WorkBannerTest` fails
  because `work()` still emits the old single-line format. This confirms the tests bind to the
  not-yet-written behaviour.

- [x] **Add the `banner()` helper.** In `bin/relay`, immediately after the `log()` function
  (currently `bin/relay:46-47`), insert:

  ```python
  def banner(lines):
      """Print a prominent #-rule banner around `lines` in the runner feed.

      Every physical line goes through log(), so it keeps the "[relay] " prefix and
      interleaves/greps cleanly with the rest of the streamed feed. Fixed 63-wide rule
      (no terminal-width detection) so logs and CI output stay deterministic."""
      rule = "#" * 63
      log("")
      log(rule)
      for line in lines:
          log(f"## {line}")
      log(rule)
  ```

- [x] **Wire `banner()` into `work()`.** In `bin/relay`, replace the single card-switch line in
  `work()` (currently `bin/relay:367`):

  ```python
      log(f"→ {ref} '{card['title']}' :: {entry['stage']} ({mode}) — then {entry['done']}")
  ```

  with a two-line banner carrying the same information:

  ```python
      banner([
          f"→ {ref}  {card['title']}",
          f"{entry['stage']} ({mode}) — then {entry['done']}",
      ])
  ```

- [x] **Run the tests, expect pass.** `python3 bin/test_relay.py` — all four tests pass
  (`Ran 4 tests ... OK`).

- [x] **Confirm item 3 (card-done marker) needs no code change.** The spec's item 3 is
  explicitly "leave the existing `✓`/`⚑`/needs-input lines as-is". Verify the existing push line
  in `work()` (currently `bin/relay:386`) already reads
  `log(f"  ✓ {ref} pushed to {entry['done']}")`, which renders as
  `[relay]   ✓ RLY-25 pushed to Spec:Review` — the exact symmetric form the spec shows. Make
  **no change** here (writing a test for unchanged `log()` behaviour would be a meaningless test).

- [x] **Manual acceptance smoke — dry-run banner.** Run a single dry pass and confirm a clear
  `#####` banner precedes the card work. From the repo root, with the runner env set
  (`RELAY_URL`, `RELAY_API_KEY`), run:

  ```
  RELAY_URL=$RELAY_URL RELAY_API_KEY=$RELAY_API_KEY bin/relay watch --once --dry-run
  ```

  Expect output of the shape (exact ref/title/stage depend on the live board; if no card is
  ready the run prints `nothing ready to work`, which is also acceptable — the banner format is
  already proven by `WorkBannerTest`):

  ```
  [relay]
  [relay] ###############################################################
  [relay] ## → RLY-25  better relay logging
  [relay] ## Spec (fresh) — then Spec:Review
  [relay] ###############################################################
  ```

- [x] **Confirm non-runner CLI output is unchanged.** `git diff --stat` shows only `bin/relay`
  modified and `bin/test_relay.py` added; the `bin/relay` diff touches only the new `banner()`
  helper and the one line inside `work()` — no edits to `print_card`, `cmd_board`, `card_line`,
  or any CLI handler.

- [x] **Commit.** `Add prominent card-switch banner to relay runner log (RLY-25)`

**Deliverable:** `python3 bin/test_relay.py` passes (4 tests), and `bin/relay watch --dry-run`
prints a fixed-width 63-`#` banner showing ref, title, stage, mode, and done target immediately
before each card's work — while every non-runner CLI command's output is byte-for-byte unchanged.

---

## Self-review notes (author)
- **Placeholder scan:** none — all test and implementation code is given in full.
- **Spec coverage:** item 1 (`banner()` helper) → step "Add the `banner()` helper" + `BannerTest`;
  item 2 (banner in `work()`) → step "Wire `banner()` into `work()`" + `WorkBannerTest`;
  item 3 (done marker) → verification step (no code change, per spec "leave as-is"); acceptance
  "dry-run prints a banner" → manual smoke step + `WorkBannerTest`; "non-runner CLI unchanged" →
  the git-diff verification step; "no new deps / pure stdlib" → harness uses only stdlib.
- **Signature consistency:** `banner(lines)` produced and consumed with the same name/shape; the
  63-`#` width is expressed as `"#" * 63` in both the helper and the tests, so they cannot drift.
- **Scope:** single coherent unit — one helper, one call site, one test file. Kept as one task
  because the helper is only meaningful once wired into `work()` (tightly coupled).
