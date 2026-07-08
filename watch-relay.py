#!/usr/bin/env python3
"""watch-relay — poll a Relay board and drive ready cards through the pipeline.

The watch loop is plain Python (zero Claude tokens while idle): it polls the board,
fingerprints it, and sleeps when nothing changed. Only when a card is *ready to work*
does it spend tokens — invoking `claude -p` for the reasoning stages (Spec/Plan/Code)
while doing the board mechanics + Deploy in shell.

Pipeline + hops come from relay.json. A card is "ready" when it sits in a stage's `from`
column (or is mid-work in an AI stage — resume), isn't blocked (needs_input), and the
target AI column is under its WIP limit. Priority is right-to-left (Deploy first).

On any stage failure the card is FLAGGED (needs_input) — which makes it blocked, so it is
never retried until a human clears it.

Usage:
  ./watch-relay.py                 # run the loop forever
  ./watch-relay.py --once          # one poll-and-work pass, then exit
  ./watch-relay.py --dry-run       # never mutate/invoke claude; just print what it WOULD do
  ./watch-relay.py --interval 30   # override idle poll seconds
Config: RELAY_URL, RELAY_API_KEY (same as bin/relay).
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
RELAY = os.path.join(ROOT, "bin", "relay")
CONFIG_PATH = os.path.join(ROOT, "relay.json")
STATE_PATH = os.path.join(ROOT, ".relay-watch-state.json")

DRY = False


def log(msg):
    print(f"[watch-relay] {msg}", flush=True)


# ---------- shell / cli helpers ----------

def sh(cmd, check=False, capture=True):
    """Run a shell command. In dry-run, print instead of running mutating commands."""
    r = subprocess.run(cmd, shell=True, cwd=ROOT, text=True,
                       capture_output=capture)
    if check and r.returncode != 0:
        log(f"! command failed ({r.returncode}): {cmd}\n{r.stderr}")
    return r


def relay(*args, mutating=True):
    """Call bin/relay. In dry-run, mutating calls are printed, read calls still run."""
    if DRY and mutating:
        log(f"  (dry) relay {' '.join(args)}")
        return None
    r = subprocess.run([RELAY, *args], cwd=ROOT, text=True, capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(f"relay {' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout.strip()


def board():
    return json.loads(relay("board", "--json", mutating=False))


def run_claude(prompt):
    """Invoke headless Claude for a reasoning stage. Returns True on success (exit 0)."""
    if DRY:
        log("  (dry) claude -p <<<\n" + "\n".join("      " + l for l in prompt.splitlines()))
        return True
    # Uses whatever auth the local Claude Code CLI has (subscription if logged in).
    r = subprocess.run(["claude", "-p", prompt], cwd=ROOT, text=True)
    return r.returncode == 0


# ---------- board reasoning ----------

def load_config():
    return json.load(open(CONFIG_PATH))


def fingerprint(b):
    rows = sorted(
        f'{c["ref"]}|{c["stage_id"]}|{c.get("status")}|{c.get("active_owner")}'
        for c in b["cards"]
    )
    return hashlib.sha256("\n".join(rows).encode()).hexdigest()


def blocked(card):
    return card.get("status") == "needs_input"


def find_ready(b, cfg):
    """The single card to work next + its stage entry + mode ('resume'|'fresh').
    Right-to-left priority (reverse pipeline order); resume before fresh within a stage."""
    stages_by_name = {s["name"]: s for s in b["stages"]}
    by_stage_id = {}
    for c in b["cards"]:
        by_stage_id.setdefault(c["stage_id"], []).append(c)

    def cards_in(name):
        s = stages_by_name.get(name)
        return by_stage_id.get(s["id"], []) if s else []

    def wip_ok(name):
        s = stages_by_name.get(name)
        limit = s.get("wip_limit") if s else None
        if not limit:
            return True
        return len(cards_in(name)) < limit

    for entry in reversed(cfg["pipeline"]):
        # resume: a card already mid-work in this AI stage (e.g. its question was answered)
        for c in cards_in(entry["stage"]):
            if c.get("status") == "working" and not blocked(c):
                return c, entry, "resume"
        # fresh: a card waiting in the `from` column, target has WIP room
        if wip_ok(entry["stage"]):
            for c in cards_in(entry["from"]):
                if not blocked(c):
                    return c, entry, "fresh"
    return None


# ---------- stage actions ----------

def slugify(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:40] or "card"


def do_spec(ref, card):
    return run_claude(f"""You are the AI working Relay card {ref} at the SPEC stage.
Read it: {RELAY} card {ref}. Design this feature (decide scope; keep it tight).
- If you genuinely need clarification, ASK the human instead of guessing:
  {RELAY} needs-input {ref} "<your question>"  — then STOP.
- Otherwise, write a concise design spec and set it as the card's DESCRIPTION:
  write the spec to a temp file, then {RELAY} describe {ref} @<that file>. Then STOP.
Do not touch git or other cards.""")


def do_plan(ref, card):
    return run_claude(f"""You are the AI working Relay card {ref} at the PLAN stage.
Read it: {RELAY} card {ref} — its DESCRIPTION is the approved spec.
Author an implementation plan at the repo root as plan.md, following this repo's
/write-plan conventions (bite-sized TDD tasks with ACTUAL test + implementation code).
Overwrite any existing plan.md. Then STOP. Do not touch git or other cards.""")


def do_code(ref, card):
    n = ref.split("-")[-1]
    branch = f"rly-{n}-{slugify(card['title'])}"
    if sh("git rev-parse --abbrev-ref HEAD").stdout.strip() != "main":
        sh("git checkout main", check=True)
    sh(f"git checkout -B {branch}", check=True)
    ok = run_claude("Run /exec-plan on the current branch to completion using the repo-root "
                    "plan.md. This is authorized — proceed without asking for confirmation. "
                    "Do not merge; exec-plan stops before the human-gated finish.")
    if not ok:
        return False
    sh(f"git push -u origin {branch}", check=True)
    return True


def do_deploy(ref, card):
    n = ref.split("-")[-1]
    # find the card's feature branch (rly-<n>-...)
    branches = sh("git branch --list 'rly-%s-*' --format '%%(refname:short)'" % n).stdout.split()
    if not branches:
        log(f"  no rly-{n}-* branch to deploy for {ref}")
        return False
    branch = branches[0]
    sh("git checkout main", check=True)
    sh(f"git merge --no-ff {branch} -m 'Merge {branch} (RLY-{n})'", check=True)
    sh("git ls-files --error-unmatch plan.md >/dev/null 2>&1 && git rm --cached plan.md "
       "&& git commit -q -m 'chore: untrack throwaway plan.md' || true")
    if sh("mix precommit").returncode != 0:
        log("  precommit failed on merge result — aborting deploy")
        return False
    sh("git push origin main", check=True)
    # gate on CI
    log("  watching CI for the deploy…")
    if sh("gh run watch $(gh run list --branch main --limit 1 --json databaseId "
          "--jq '.[0].databaseId') --exit-status").returncode != 0:
        log("  CI failed — not moving to Deploy:Done")
        return False
    sh(f"git branch -d {branch} || true")
    return True


ACTIONS = {"spec": do_spec, "plan": do_plan, "code": do_code, "deploy": do_deploy}


# ---------- one card ----------

def flag(ref, reason):
    log(f"  ⚑ flagging {ref}: {reason}")
    try:
        relay("needs-input", ref, f"[auto] stage failed: {reason}. A human needs to look — "
                                  f"the runner won't retry until this is cleared.")
    except Exception as e:
        log(f"  (could not flag {ref}: {e})")


def status_after_push(done_stage):
    return "in_review" if done_stage.lower().endswith(":review") else "queued"


def work(card, entry, mode):
    ref = card["ref"]
    target, done, action = entry["stage"], entry["done"], entry["action"]
    log(f"→ {ref} '{card['title']}' :: {action} ({mode}) — {target} then {done}")
    if DRY:
        run_claude(f"[{action} for {ref}]")  # prints the intended prompt
        return
    try:
        relay("own", ref)
        if mode == "fresh":
            relay("move", ref, target)
        relay("status", ref, "working")
        ok = ACTIONS[action](ref, card)
    except Exception as e:
        flag(ref, f"{target}: {e}")
        return

    after = json.loads(relay("card", ref, "--json", mutating=False))["data"]
    if after.get("status") == "needs_input":
        log(f"  {ref} asked the human a question — left blocked in {target}")
        return
    if not ok:
        flag(ref, f"{target} stage did not complete")
        return
    relay("comment", ref, f"{target} done → pushing to {done}")
    relay("move", ref, done)
    relay("status", ref, status_after_push(done))
    relay("release", ref)
    log(f"  ✓ {ref} pushed to {done}")


# ---------- loop ----------

def state_get():
    try:
        return json.load(open(STATE_PATH)).get("fingerprint")
    except Exception:
        return None


def state_set(fp):
    if not DRY:
        json.dump({"fingerprint": fp}, open(STATE_PATH, "w"))


def tick(cfg):
    """One pass: returns True if it did work (board changed → re-poll immediately)."""
    b = board()
    fp = fingerprint(b)
    if fp == state_get():
        return False  # unchanged — cheap, no tokens
    log("board changed — scanning for ready work")
    ready = find_ready(b, cfg)
    if not ready:
        log("  nothing ready to work")
        state_set(fp)
        return False
    card, entry, mode = ready
    work(card, entry, mode)
    state_set(None if not DRY else fp)  # force a re-poll next loop after doing work
    return True


def main():
    global DRY
    ap = argparse.ArgumentParser(prog="watch-relay")
    ap.add_argument("--once", action="store_true", help="one pass then exit")
    ap.add_argument("--dry-run", action="store_true", help="print actions; never mutate/invoke claude")
    ap.add_argument("--interval", type=int, help="idle poll seconds (default from relay.json)")
    args = ap.parse_args()
    DRY = args.dry_run
    cfg = load_config()
    interval = args.interval or cfg.get("poll_interval", 45)
    if not os.environ.get("RELAY_URL") or not os.environ.get("RELAY_API_KEY"):
        sys.exit("RELAY_URL / RELAY_API_KEY must be set")
    log(f"watching {os.environ['RELAY_URL']} every {interval}s"
        + (" (dry-run)" if DRY else "") + (" — one pass" if args.once else ""))
    while True:
        did = tick(cfg)
        if args.once:
            break
        if not did:
            time.sleep(interval)


if __name__ == "__main__":
    main()
