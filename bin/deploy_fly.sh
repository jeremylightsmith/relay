#!/usr/bin/env bash
# Deploy HEAD to Fly and wait until the board serves it. The Deploy flow's always-on step.
#
#   bin/op_deploy.sh bin/deploy_fly.sh        (needs FLY_API_TOKEN; see .relay/deploy.env)
#
# Reproduces CI's `Deploy app` job (`flyctl deploy --remote-only` with the GIT_SHA / BUILT_AT
# build args the Dockerfile stamps into /api/version), then polls `relay version --field sha`
# every DEPLOY_POLL_SECONDS (default 15) until it equals HEAD, for at most
# DEPLOY_TIMEOUT_SECONDS (default 600). No internal retry: the flow node's max_retries does that.

set -euo pipefail

say() { echo "deploy_fly: $*"; }
fail() {
  echo "deploy_fly: $*" >&2
  exit 1
}

# Missing = unset, empty, or still an `op://` reference (the script ran outside `op run`).
missing=""
for name in FLY_API_TOKEN; do
  value="${!name:-}"
  case "$value" in "" | op://*) missing="$missing $name" ;; esac
done
[ -z "$missing" ] || fail "missing required variables:$missing — run through bin/op_deploy.sh (see .relay/deploy.env)"

relay="${RELAY:-./relay}"
poll="${DEPLOY_POLL_SECONDS:-15}"
timeout="${DEPLOY_TIMEOUT_SECONDS:-600}"

sha="$(git rev-parse HEAD)"
built_at="$(git log -1 --format=%cI HEAD)"

say "deploying $sha to Fly"
flyctl deploy --remote-only --build-arg "GIT_SHA=$sha" --build-arg "BUILT_AT=$built_at"

deadline=$(($(date +%s) + timeout))
while :; do
  live="$("$relay" version --field sha 2>/dev/null || true)"
  if [ "$live" = "$sha" ]; then
    say "live at $sha"
    exit 0
  fi
  [ "$(date +%s)" -lt "$deadline" ] || fail "live version is ${live:-unknown}, expected $sha — gave up after ${timeout}s"
  say "live version is ${live:-unknown}, waiting for $sha"
  sleep "$poll"
done
