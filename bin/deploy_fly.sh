#!/usr/bin/env bash
# Deploy HEAD to Fly and wait until the board serves it. The Deploy flow's always-on step.
#
#   bin/deploy_fly.sh [<REF>]        (needs FLY_API_TOKEN in the environment, e.g. from .envrc.local)
#
# Only a card targeting main is deployed (RE458; the target is HAMACA_TARGET via target_lib.sh).
# Any other target comments `Not deployed: <REF> targets <target>` on the card and exits 0 —
# before the secrets check, since a deploy that never happens needs no FLY_API_TOKEN. <REF> is
# required then (the comment needs a card); on main it is optional, so a hand run still works.
#
# Reproduces CI's `Deploy app` job (`flyctl deploy --remote-only` with the GIT_SHA / BUILT_AT
# build args the Dockerfile stamps into /api/version), then polls `hamaca version --field sha`
# every DEPLOY_POLL_SECONDS (default 15) until it equals HEAD, for at most
# DEPLOY_TIMEOUT_SECONDS (default 600). No internal retry: the flow node's max_retries does that.
# Exits 0 without deploying when the live SHA already equals HEAD (see the pre-check below).

set -euo pipefail
. "$(dirname "$0")/target_lib.sh"

say() { echo "deploy_fly: $*"; }
fail() {
  echo "deploy_fly: $*" >&2
  exit 1
}

ref="${1:-}"
hamaca="${HAMACA:-./hamaca}"

if ! target_is_deploy_branch; then
  if [ -z "$ref" ]; then
    echo "usage: bin/deploy_fly.sh <REF>   (required when the target, $TARGET, is not $DEPLOY_BRANCH)" >&2
    exit 64
  fi
  say "$ref targets $TARGET, not $DEPLOY_BRANCH — not deploying"
  "$hamaca" comment "$ref" "Not deployed: $ref targets $TARGET"
  exit 0
fi

missing=""
for name in FLY_API_TOKEN; do
  value="${!name:-}"
  [ -n "$value" ] || missing="$missing $name"
done
[ -z "$missing" ] || fail "missing required variables:$missing — export them in the runner's environment (e.g. .envrc.local), then restart it"

poll="${DEPLOY_POLL_SECONDS:-15}"
timeout="${DEPLOY_TIMEOUT_SECONDS:-600}"

sha="$(git rev-parse HEAD)"
built_at="$(git log -1 --format=%cI HEAD)"

# Idempotent: deploying Hamaca restarts the board, and its boot resume re-runs this node. A HEAD
# that is already live is a finished deploy, not a reason to deploy (and restart) again.
if [ "$("$hamaca" version --field sha 2>/dev/null || true)" = "$sha" ]; then
  say "$sha is already live — skipping the deploy"
  exit 0
fi

say "deploying $sha to Fly"
flyctl deploy --remote-only --build-arg "GIT_SHA=$sha" --build-arg "BUILT_AT=$built_at"

deadline=$(($(date +%s) + timeout))
while :; do
  live="$("$hamaca" version --field sha 2>/dev/null || true)"
  if [ "$live" = "$sha" ]; then
    say "live at $sha"
    exit 0
  fi
  [ "$(date +%s)" -lt "$deadline" ] || fail "live version is ${live:-unknown}, expected $sha — gave up after ${timeout}s"
  say "live version is ${live:-unknown}, waiting for $sha"
  sleep "$poll"
done
