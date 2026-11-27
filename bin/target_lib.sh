# The card's target branch, for the RE board's bin scripts (RE458). Sourced, never executed:
#
#   . "$(dirname "$0")/target_lib.sh"
#
# DEPLOY_BRANCH is the ONE place this repo names the branch CI runs on and Fly/TestFlight/Play
# deploy from. TARGET is the branch the card ships to: the runner exports the run's frozen
# target as HAMACA_TARGET (RELAY_TARGET is the older twin); neither set (an old runner, or a
# script run by hand) means main.
#
# Safe under `set -euo pipefail`: no `set`, no `exit`, every read defaulted.

DEPLOY_BRANCH=main
TARGET="${HAMACA_TARGET:-${RELAY_TARGET:-$DEPLOY_BRANCH}}"

# 0 iff the card ships to the deploy branch, so its CI and Deploy apply.
target_is_deploy_branch() {
  [ "$TARGET" = "$DEPLOY_BRANCH" ]
}
