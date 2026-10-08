#!/usr/bin/env bash
# Ship a card's Flutter change to TestFlight. The Deploy flow's iOS step.
#
#   bin/deploy_ios.sh <REF>        (run from the repo root, on origin/main)
#
# 1. Skips (exit 0) when the card's commit on main didn't touch flutter/ — BEFORE looking at any
#    secret, so a web-only card never fails on missing mobile credentials.
# 2. Fails fast naming every missing secret (unset or empty). Secrets come from the
#    environment, e.g. exported in .envrc.local in the runner's direnv shell.
# 3. bin/flutter_validate.sh, then in flutter/ios: `fastlane ios next_build_number` (the next
#    TestFlight build number), `fastlane deploy` (build, sign via read-only match, upload), and,
#    unless TESTFLIGHT_EXTERNAL is the literal `false`, `fastlane ios distribute_external`.
#
# APP_STORE_CONNECT_PRIVATE_KEY may be the raw .p8 PEM or its base64. It is written to a temp
# file for FASTLANE_API_KEY_PATH; every temp file is removed on every exit path. No internal
# retry: the flow node's max_retries does that.

set -euo pipefail

say() { echo "deploy_ios: $*"; }
fail() {
  echo "deploy_ios: $*" >&2
  exit 1
}

ref="${1:-}"
if [ -z "$ref" ]; then
  echo "usage: bin/deploy_ios.sh <REF>" >&2
  exit 2
fi

touched=0
"$(dirname "$0")/card_touched_flutter.sh" "$ref" || touched=$?
case "$touched" in
  0) ;;
  1)
    say "no flutter/ changes for $ref — skipping iOS"
    exit 0
    ;;
  *) fail "could not tell whether $ref touched flutter/ (card_touched_flutter exited $touched)" ;;
esac

missing=""
for name in APP_STORE_CONNECT_PRIVATE_KEY APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID \
  MATCH_PASSWORD MATCH_GIT_BASIC_AUTHORIZATION RELAY_BASE_URL GOOGLE_IOS_CLIENT_ID \
  GOOGLE_SERVER_CLIENT_ID; do
  value="${!name:-}"
  [ -n "$value" ] || missing="$missing $name"
done
[ -z "$missing" ] || fail "missing required variables:$missing — export them in the runner's environment (e.g. .envrc.local), then restart it"

key_file=""
number_file=""
cleanup() {
  [ -z "$key_file" ] || rm -f "$key_file"
  [ -z "$number_file" ] || rm -f "$number_file"
}
trap cleanup EXIT

umask 077
key_file="$(mktemp)"
case "$APP_STORE_CONNECT_PRIVATE_KEY" in
  *"-----BEGIN"*) printf '%s\n' "$APP_STORE_CONNECT_PRIVATE_KEY" >"$key_file" ;;
  *) printf '%s' "$APP_STORE_CONNECT_PRIVATE_KEY" | base64 --decode >"$key_file" ;;
esac
number_file="$(mktemp)"

APP_VERSION="$(grep -E '^version:' flutter/pubspec.yaml | sed -E 's/^version:[[:space:]]*//' | cut -d+ -f1)"
[ -n "$APP_VERSION" ] || fail "no version: in flutter/pubspec.yaml"
export APP_VERSION FASTLANE_API_KEY_PATH="$key_file" RELAY_DEPLOY=1

"$(dirname "$0")/flutter_validate.sh"

cd flutter/ios

say "looking up the next TestFlight build number"
RELAY_BUILD_NUMBER_FILE="$number_file" fastlane ios next_build_number
BUILD_NUMBER="$(tr -d '[:space:]' <"$number_file")"
case "$BUILD_NUMBER" in
  "" | *[!0-9]*) fail "fastlane ios next_build_number wrote '$BUILD_NUMBER', not a build number" ;;
esac
export BUILD_NUMBER

say "building and uploading $APP_VERSION ($BUILD_NUMBER) to TestFlight"
fastlane deploy

if [ "${TESTFLIGHT_EXTERNAL:-true}" = false ]; then
  say "TESTFLIGHT_EXTERNAL=false — internal testers only, skipping external distribution"
else
  say "distributing $APP_VERSION ($BUILD_NUMBER) to the external TestFlight group"
  fastlane ios distribute_external
fi

say "shipped $ref to TestFlight as $APP_VERSION ($BUILD_NUMBER)"
