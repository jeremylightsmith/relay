#!/usr/bin/env bash
# Wait until main's CI has passed on the commit the Code flow just shipped. The RE board's
# `await_ci` node, between `merge` (bin/ship_to_main.sh) and `post`, so a card only reaches
# Code:Done (and the Deploy flow) once CI agrees with the local gates.
#
#   bin/await_main_ci.sh [<sha>]        (default: HEAD — what ship_to_main.sh pushed)
#
# Which run counts: the `AWAIT_CI_WORKFLOW` workflow (default `ci.yml`) on a push to main for
# exactly that commit. Polls every AWAIT_POLL_SECONDS (default 30) for at most
# AWAIT_TIMEOUT_SECONDS (default 1800).
#
# A failed run is re-run ONCE (failed jobs only) before giving up: the browser suite flakes, and
# one flake shouldn't send the card to the ci-fixer. Exits nonzero with
# `await_main_ci: FAILED: <reason>` on stderr — the line the ci-fixer agent reads.

set -euo pipefail

sha="${1:-$(git rev-parse HEAD)}"
workflow="${AWAIT_CI_WORKFLOW:-ci.yml}"
poll="${AWAIT_POLL_SECONDS:-30}"
deadline=$(($(date +%s) + ${AWAIT_TIMEOUT_SECONDS:-1800}))

say() { echo "await_main_ci: $*" >&2; }
fail() {
  say "FAILED: $*"
  exit 1
}
tick() {
  [ "$(date +%s)" -lt "$deadline" ] || fail "timed out waiting: $1"
  sleep "$poll"
}

while :; do
  id="" status="" conclusion="" attempt="" url=""
  # `none` stands in for a null conclusion so the tab-separated fields never collapse.
  IFS=$'\t' read -r id status conclusion attempt url < <(gh run list --workflow "$workflow" \
    --branch main --event push --commit "$sha" --limit 1 \
    --json databaseId,status,conclusion,attempt,url \
    -q '.[0] // empty | [.databaseId, .status, (.conclusion // "" | if . == "" then "none" else . end), .attempt, .url] | @tsv') || true

  if [ -z "$id" ]; then
    say "no main CI run for $sha yet — waiting"
    tick "a main CI run for $sha to start"
    continue
  fi

  if [ "$status" != completed ]; then
    say "main CI run $id for $sha is $status — waiting"
    tick "main CI run $id for $sha"
    continue
  fi

  case "$conclusion" in
    success)
      say "main CI passed for $sha: $url"
      exit 0
      ;;
    cancelled) fail "main CI run for $sha was cancelled: $url" ;;
  esac

  jobs="$(gh run view "$id" --json jobs \
    -q '[.jobs[] | select(.conclusion == "failure") | .name] | join(", ")' || true)"
  # A run's `attempt` goes up on every re-run, so "attempt 1 failed" means nobody re-ran it yet.
  [ "$attempt" = 1 ] || fail "main CI failed again for $sha after a re-run (${jobs:-unknown jobs}): $url"
  say "main CI $conclusion for $sha (${jobs:-unknown jobs}) — re-running the failed jobs once"
  gh run rerun "$id" --failed
  tick "main CI run $id for $sha to re-run"
done
