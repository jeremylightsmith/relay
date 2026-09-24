#!/usr/bin/env bash
# Wait until a card's PR is merged AND main's CI has passed and deployed it.
#
# The Code flow's `deploy` node runs this after `merge` has queued a squash auto-merge, so a card
# only lands in Review once its change is actually live.
#
#   bin/await_deploy.sh <pr-url-or-number>
#
# Which CI run counts: the `AWAIT_CI_WORKFLOW` workflow (default `ci.yml`) on pushes to main, and
# within it the `AWAIT_DEPLOY_JOB` job (default `Deploy app`, this repo's Fly deploy).
#
# Exits 0 once a green main CI run whose commit contains the merge has run the deploy job.
# Exits nonzero, with the reason on stderr, when the PR is closed unmerged or conflicts with
# main, its checks fail, main's CI fails, or AWAIT_TIMEOUT_SECONDS (default 20 min) runs out.
#
# A failed CI run is re-run ONCE (failed jobs only) before giving up, on the PR and again on
# main: the browser suite flakes, and one flake shouldn't park the card for a human.
#
# "Contains the merge" rather than "is the merge": the deploy job shares one concurrency group,
# so a newer push to main can cancel this commit's pending deploy. A later green run that
# includes this commit still deploys it, and counts.

set -euo pipefail

pr="${1:?usage: bin/await_deploy.sh <pr-url-or-number>}"
workflow="${AWAIT_CI_WORKFLOW:-ci.yml}"
deploy_job="${AWAIT_DEPLOY_JOB:-Deploy app}"
poll="${AWAIT_POLL_SECONDS:-30}"
deadline=$(($(date +%s) + ${AWAIT_TIMEOUT_SECONDS:-1200}))

say() { echo "await_deploy: $*" >&2; }
fail() {
  say "FAILED: $*"
  exit 1
}
tick() {
  [ "$(date +%s)" -lt "$deadline" ] || fail "timed out waiting: $1"
  sleep "$poll"
}

# ── 1. the PR merges ────────────────────────────────────────────────────────────────────────
while :; do
  state="" merge_state="" head="" auto="" failed_run="" attempt=""
  read -r state merge_state head auto < <(gh pr view "$pr" \
    --json state,mergeStateStatus,headRefOid,autoMergeRequest \
    -q '[.state, .mergeStateStatus, .headRefOid, (.autoMergeRequest != null)] | @tsv') || true

  case "$state" in
    MERGED) break ;;
    CLOSED) fail "PR $pr was closed without merging" ;;
    "")
      say "could not read PR $pr — retrying"
      tick "PR $pr to be readable"
      continue
      ;;
  esac
  [ "$merge_state" != DIRTY ] || fail "PR $pr conflicts with main — rebase it (resync) and push"

  # Auto-merge waits on the required checks, so a red one would otherwise mean waiting forever.
  # A run's `attempt` goes up on every re-run, so "attempt 1 failed" means nobody re-ran it yet.
  read -r failed_run attempt < <(gh run list --workflow "$workflow" --commit "$head" --event pull_request \
    --json databaseId,attempt,status,conclusion \
    -q 'map(select(.status == "completed" and .conclusion != "success" and .conclusion != "skipped")) | .[0] // empty | [.databaseId, .attempt] | @tsv') || true
  if [ -n "$failed_run" ]; then
    [ "$attempt" = 1 ] || fail "PR $pr checks failed again after a re-run: $(gh run view "$failed_run" --json url -q .url)"
    say "PR checks failed (run $failed_run) — re-running the failed jobs once"
    gh run rerun "$failed_run" --failed
  elif [ "$auto" != true ] && [ "$merge_state" = CLEAN ]; then
    fail "PR $pr is green and mergeable but auto-merge is not enabled"
  fi

  say "PR $pr is $state ($merge_state) — waiting for it to merge"
  tick "PR $pr to merge"
done

sha=$(gh pr view "$pr" --json mergeCommit -q .mergeCommit.oid)
say "PR $pr merged as $sha — waiting for main CI to deploy it"

# ── 2. main's CI passes and deploys that commit ──────────────────────────────────────────
contains_merge() { [ "$1" = "$sha" ] || git merge-base --is-ancestor "$sha" "$1" 2>/dev/null; }

while :; do
  git fetch --quiet origin main || true # a failed fetch just means "not yet" for newer runs

  own_done="" newer_pending=""
  while IFS=$'\t' read -r id head status conclusion attempt; do
    contains_merge "$head" || continue

    if [ "$status" != completed ]; then
      [ "$head" = "$sha" ] || newer_pending=$id
    elif [ "$conclusion" = success ]; then
      deploy=$(gh run view "$id" --json jobs | jq -r --arg job "$deploy_job" '.jobs[] | select(.name == $job) | .conclusion')
      if [ "$deploy" = success ]; then
        say "deployed by run $id ($head) — done"
        exit 0
      fi
    elif [ "$head" = "$sha" ]; then
      own_done="$id $conclusion $attempt"
    fi
  done < <(gh run list --workflow "$workflow" --branch main --event push --limit 20 \
    --json databaseId,headSha,status,conclusion,attempt \
    -q '.[] | [.databaseId, .headSha, .status, .conclusion, .attempt] | @tsv')

  if [ -n "$own_done" ] && [ -z "$newer_pending" ]; then
    read -r id conclusion attempt <<<"$own_done"
    url=$(gh run view "$id" --json url -q .url)
    [ "$conclusion" != cancelled ] || fail "main CI run for $sha was cancelled and no newer run is deploying it: $url"
    [ "$attempt" = 1 ] || fail "main CI failed again for $sha after a re-run: $url"
    say "main CI $conclusion for $sha (run $id) — re-running the failed jobs once"
    gh run rerun "$id" --failed
  fi

  tick "main CI to deploy $sha"
done
