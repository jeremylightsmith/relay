#!/usr/bin/env bash
# Ship a card's Flutter change to Google Play's internal track. The Deploy flow's Android step.
#
#   bin/deploy_android.sh <REF>        (run from the repo root, on origin/main)
#
# 1. Skips (exit 0) when the card's commit on main didn't touch flutter/.
# 2. Skips (exit 0) while the Android credentials don't exist yet (RLY-103): any one unset or
#    empty in the environment means "not yet".
# 3. bin/flutter_validate.sh, then in flutter/android: `fastlane android next_build_number` and
#    `fastlane deploy` (build the App Bundle, upload to the internal track).
#
# The keystore, flutter/android/key.properties (read by app/build.gradle.kts, gitignored) and the
# Play service-account JSON are written for the run and removed on every exit path. No internal
# retry: the flow node's max_retries does that.

set -euo pipefail

say() { echo "deploy_android: $*"; }
fail() {
  echo "deploy_android: $*" >&2
  exit 1
}

ref="${1:-}"
if [ -z "$ref" ]; then
  echo "usage: bin/deploy_android.sh <REF>" >&2
  exit 2
fi

touched=0
"$(dirname "$0")/card_touched_flutter.sh" "$ref" || touched=$?
case "$touched" in
  0) ;;
  1)
    say "no flutter/ changes for $ref — skipping Android"
    exit 0
    ;;
  *) fail "could not tell whether $ref touched flutter/ (card_touched_flutter exited $touched)" ;;
esac

for name in ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_PASSWORD \
  ANDROID_KEY_ALIAS PLAY_STORE_CONFIG_JSON_BASE64; do
  if [ -z "${!name:-}" ]; then
    say "Android credentials not configured — skipping Play deploy (RLY-103)"
    exit 0
  fi
done

key_properties="$PWD/flutter/android/key.properties" # absolute: the trap runs after the cd below
keystore=""
play_json=""
number_file=""
wrote_properties=0
cleanup() {
  [ "$wrote_properties" = 0 ] || rm -f "$key_properties"
  [ -z "$keystore" ] || rm -f "$keystore"
  [ -z "$play_json" ] || rm -f "$play_json"
  [ -z "$number_file" ] || rm -f "$number_file"
}
trap cleanup EXIT

umask 077
keystore="$(mktemp)"
printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 --decode >"$keystore"
play_json="$(mktemp)"
printf '%s' "$PLAY_STORE_CONFIG_JSON_BASE64" | base64 --decode >"$play_json"
number_file="$(mktemp)"

wrote_properties=1
cat >"$key_properties" <<PROPERTIES
storePassword=$ANDROID_KEYSTORE_PASSWORD
keyPassword=$ANDROID_KEY_PASSWORD
keyAlias=$ANDROID_KEY_ALIAS
storeFile=$keystore
PROPERTIES

export PLAY_STORE_CONFIG_JSON_PATH="$play_json"

"$(dirname "$0")/flutter_validate.sh"

cd flutter/android

say "looking up the next Play internal-track version code"
RELAY_BUILD_NUMBER_FILE="$number_file" fastlane android next_build_number
BUILD_NUMBER="$(tr -d '[:space:]' <"$number_file")"
case "$BUILD_NUMBER" in
  "" | *[!0-9]*) fail "fastlane android next_build_number wrote '$BUILD_NUMBER', not a build number" ;;
esac
export BUILD_NUMBER

say "building and uploading build $BUILD_NUMBER to the Play internal track"
fastlane deploy

say "shipped $ref to Google Play internal testing as build $BUILD_NUMBER"
