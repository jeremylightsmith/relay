#!/usr/bin/env bash
# Capture the four raw App Store screenshots (RE479) from the Hamaca build on an iPhone 6.9"
# simulator, against the local dev server seeded with the "Forkful" board:
#
#     mix run priv/repo/store_screenshot_seeds.exs   # seed (idempotent)
#     mix phx.server                                 # in another terminal (:4003, or $PORT)
#     bin/capture_store_screenshots.sh [SIMULATOR_UDID]
#
# Runs flutter/integration_test/store_screenshots_test.dart, which walks the real app to each
# screen and prints `HAMACA_SHOT <name>` once it has settled; on each marker this runs
# `xcrun simctl io <udid> screenshot` into flutter/ios/fastlane/screenshots_raw/en-US/<name>.png.
# Then frame them with `node bin/store-screenshots.mjs`. Flutter can't capture the screens
# itself: the board and card body are WKWebViews, and the status bar isn't Flutter's.
#
# With no UDID it uses the first available iPhone 16+ Pro Max simulator, booting it if needed.
# The status bar is pinned to 9:41 / full signal / full battery and the appearance to light for
# the run, and the override is cleared on every exit path.

set -euo pipefail

# The `mix phx.server` dev server — never prod: nothing is staged there.
BASE_URL="http://localhost:${PORT:-4003}"
SHOTS=(01_needs_you 02_board 03_review 04_answer)

say() { echo "capture_store_screenshots: $*"; }
die() { say "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/flutter/ios/fastlane/screenshots_raw/en-US"

# An iPhone 6.9" display: the 16 Pro Max or any later Pro Max.
is_six_nine() { [[ "$1" =~ ^iPhone\ (1[6-9]|[2-9][0-9])\ Pro\ Max$ ]]; }

device_name() {
  xcrun simctl list devices available | sed -n "s/^ *\(.*\) ($1) (.*$/\1/p" | head -1
}

udid="${1:-}"
if [[ -z "$udid" ]]; then
  udid="$(xcrun simctl list devices available |
    sed -n 's/^ *\(iPhone [0-9]* Pro Max\) (\([0-9A-F-]*\)) (.*$/\1|\2/p' |
    while IFS='|' read -r name id; do is_six_nine "$name" && { echo "$id"; break; }; done || true)"
  [[ -n "$udid" ]] || die "no iPhone 16 Pro Max (or newer Pro Max) simulator found; create one in Xcode"
fi

name="$(device_name "$udid")"
[[ -n "$name" ]] || die "no available simulator with UDID $udid"
is_six_nine "$name" || die "$name is not a 6.9\" iPhone; use an iPhone 16 Pro Max or newer"

curl -s -o /dev/null --max-time 5 "$BASE_URL/" ||
  die "the dev server on $BASE_URL doesn't answer. Seed it (mix run priv/repo/store_screenshot_seeds.exs), then start it (mix phx.server)"

if ! xcrun simctl list devices | grep -q "($udid) (Booted)"; then
  say "booting $name ($udid)"
  xcrun simctl boot "$udid"
fi
xcrun simctl bootstatus "$udid" -b >/dev/null

trap 'xcrun simctl status_bar "$udid" clear || true' EXIT
xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
xcrun simctl ui "$udid" appearance light

mkdir -p "$OUT"
for shot in "${SHOTS[@]}"; do rm -f "$OUT/$shot.png"; done

say "running the integration test on $name ($udid)"
cd "$ROOT/flutter"
set +e
flutter test integration_test/store_screenshots_test.dart -d "$udid" \
  --dart-define=RELAY_BASE_URL="$BASE_URL" 2>&1 |
  while IFS= read -r line; do
    echo "$line"
    if [[ "$line" =~ HAMACA_SHOT\ ([0-9a-z_]+) ]]; then
      shot="${BASH_REMATCH[1]}"
      xcrun simctl io "$udid" screenshot --type=png "$OUT/$shot.png" >/dev/null 2>&1 &&
        say "captured $shot.png" || say "FAILED to capture $shot.png"
    fi
  done
status="${PIPESTATUS[0]}"
set -e

[[ "$status" == 0 ]] || die "the integration test failed (exit $status)"
for shot in "${SHOTS[@]}"; do
  [[ -f "$OUT/$shot.png" ]] || die "no $shot.png was captured"
done
say "ok: ${#SHOTS[@]} raw shots in ${OUT#"$ROOT"/}; now run: node bin/store-screenshots.mjs"
