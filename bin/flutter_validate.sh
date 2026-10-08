#!/usr/bin/env bash
# Validate the Flutter app before a store deploy: the same checks, in the same order, as the
# `validate` job in .github/workflows/flutter-deploy.yml. Shared by bin/deploy_ios.sh and
# bin/deploy_android.sh, and backs the RE Code flow's pre-merge `flutter` gate
# (bin/flutter_gate.sh).
#
#   bin/flutter_validate.sh        (run from the repo root; works in ./flutter)
#
# Stops at the first failing command and exits with its status. Non-mutating: the format check
# reports unformatted files (`--output=none`) instead of rewriting them.

set -euo pipefail

say() { echo "flutter_validate: $*"; }

cd flutter

say "flutter pub get"
flutter pub get
say "flutter analyze"
flutter analyze
say "dart format --output=none --set-exit-if-changed ."
dart format --output=none --set-exit-if-changed .
say "flutter test"
flutter test
say "ok"
