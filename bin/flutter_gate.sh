#!/usr/bin/env bash
# The RE Code flow's pre-merge `flutter` gate: validate the Flutter app only when the card's
# branch touched flutter/.
#
#   bin/flutter_gate.sh        (run from the repo root, on the card's branch)
#
# Exit 0: the branch did not touch flutter/ (validator not run), or the validator passed.
# Exit N: the branch touched flutter/ and bin/flutter_validate.sh exited N (exec'd, so exact).
# Exit 1: flutter/ needs validating but `flutter` is not on PATH.
#
# Branch-scoped: compares `git merge-base origin/<target> HEAD` with HEAD — <target> being the
# card's target branch (RE458; HAMACA_TARGET via target_lib.sh, main by default) — so only
# committed work counts: uncommitted changes in the worktree don't ship and don't trigger the
# gate. If the merge-base can't be computed (say, the target branch is gone), it validates
# anyway: a detection error fails toward validating, never toward passing.
#
# No `git diff | grep -q` here: under pipefail, grep exiting on its first match SIGPIPEs a
# large diff and the pipeline reads as "did not touch flutter/". `git diff --quiet` with a
# pathspec answers the question without a pipe.
#
# Read-only: never fetches and never moves HEAD — the flow's sync / final_fix nodes have
# already positioned the branch.

set -euo pipefail
. "$(dirname "$0")/target_lib.sh"

say() { echo "flutter_gate: $*"; }
warn() { echo "flutter_gate: $*" >&2; }

if base=$(git merge-base "origin/$TARGET" HEAD 2>/dev/null); then
  if git diff --quiet "$base" HEAD -- flutter/; then
    say "branch did not touch flutter/ — skipping"
    exit 0
  fi
  say "branch touched flutter/ — validating"
else
  warn "could not compute merge-base with origin/$TARGET — validating anyway"
fi

if ! command -v flutter >/dev/null 2>&1; then
  warn "flutter not found on PATH"
  exit 1
fi

exec "$(dirname "$0")/flutter_validate.sh"
