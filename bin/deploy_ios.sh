#!/usr/bin/env bash
# Ship a card's Flutter change to TestFlight. The Deploy flow's iOS step.
#
#   bin/deploy_ios.sh <REF>        (run from the repo root, on origin/main)
#   bin/deploy_ios.sh --head       (by hand, via `prod deploy_ios`: ship the checkout as-is)
#
# 1. Skips (exit 0) when the card's commit on main didn't touch flutter/ — BEFORE looking at any
#    secret, so a web-only card never fails on missing mobile credentials.
# 2. Fails fast naming every missing secret (unset or empty). Secrets come from the
#    environment, e.g. exported in .envrc.local in the runner's direnv shell.
# 3. bin/flutter_validate.sh, then in flutter/ios: `fastlane ios next_build_number` (the next
#    TestFlight build number), `fastlane deploy` (build, sign via read-only match, upload), and,
#    unless TESTFLIGHT_EXTERNAL is the literal `false`, `fastlane ios distribute_external`.
# 4. Only when the card changed the App Store listing ($listing_paths) — or always with --head —
#    `fastlane ios upload_listing`: metadata + screenshots, never a binary, never a review
#    submission. It runs after TestFlight, so a listing problem never holds back testers.
#
# APP_STORE_CONNECT_PRIVATE_KEY may be the raw .p8 PEM or its base64. It is written to a temp
# file for FASTLANE_API_KEY_PATH; every temp file is removed on every exit path. No internal
# retry: the flow node's max_retries does that.
#
# The build rewrites tracked files (increment_build_number stamps the build number into the
# project and Info.plist; fastlane regenerates its README). They are snapshotted first and put
# back on every exit path, so a deploy leaves the checkout as it found it and the next
# `prod deploy_ios` isn't refused as dirty.

set -euo pipefail

say() { echo "deploy_ios: $*"; }
fail() {
  echo "deploy_ios: $*" >&2
  exit 1
}

ref="${1:-}"
if [ -z "$ref" ]; then
  echo "usage: bin/deploy_ios.sh <REF> | --head" >&2
  exit 2
fi

bin_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$PWD" # absolute: the listing check runs after the cd below, and pathspecs are cwd-relative
# The App Store listing (fastlane deliver's metadata + screenshots); see step 4.
listing_paths="flutter/ios/fastlane/metadata flutter/ios/fastlane/screenshots"

touched=0
if [ "$ref" = --head ]; then
  ref=HEAD
else
  "$bin_dir/card_touched_flutter.sh" "$ref" || touched=$?
fi
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
snapshot=""
stamped_files="Runner.xcodeproj/project.pbxproj Runner/Info.plist fastlane/README.md"
ios_dir="$repo_root/flutter/ios" # absolute: the trap runs after the cd below
cleanup() {
  [ -z "$key_file" ] || rm -f "$key_file"
  [ -z "$number_file" ] || rm -f "$number_file"
  if [ -n "$snapshot" ]; then
    for f in $stamped_files; do
      [ ! -f "$snapshot/$f" ] || cp "$snapshot/$f" "$ios_dir/$f"
    done
    rm -rf "$snapshot"
  fi
}
trap cleanup EXIT

umask 077
key_file="$(mktemp)"
case "$APP_STORE_CONNECT_PRIVATE_KEY" in
  *"-----BEGIN"*) printf '%s\n' "$APP_STORE_CONNECT_PRIVATE_KEY" >"$key_file" ;;
  *) printf '%s' "$APP_STORE_CONNECT_PRIVATE_KEY" | base64 --decode >"$key_file" ;;
esac
number_file="$(mktemp)"
snapshot="$(mktemp -d)"
for f in $stamped_files; do
  [ ! -f "$ios_dir/$f" ] || { mkdir -p "$snapshot/$(dirname "$f")" && cp "$ios_dir/$f" "$snapshot/$f"; }
done

APP_VERSION="$(grep -E '^version:' flutter/pubspec.yaml | sed -E 's/^version:[[:space:]]*//' | cut -d+ -f1)"
[ -n "$APP_VERSION" ] || fail "no version: in flutter/pubspec.yaml"
export APP_VERSION FASTLANE_API_KEY_PATH="$key_file" RELAY_DEPLOY=1

"$bin_dir/flutter_validate.sh"

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

listing=0
if [ "$ref" != HEAD ]; then
  # $listing_paths unquoted on purpose: one pathspec per word
  (cd "$repo_root" && "$bin_dir/card_touched_flutter.sh" "$ref" $listing_paths) || listing=$?
fi
case "$listing" in
  0)
    say "uploading the App Store listing (metadata + screenshots)"
    fastlane ios upload_listing
    ;;
  1) say "listing unchanged for $ref — skipping the App Store listing" ;;
  *) fail "could not tell whether $ref changed the App Store listing (card_touched_flutter exited $listing)" ;;
esac

say "shipped $ref to TestFlight as $APP_VERSION ($BUILD_NUMBER)"
