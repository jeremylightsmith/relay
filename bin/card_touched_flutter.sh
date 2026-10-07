#!/usr/bin/env bash
# Did a card's commit on main touch flutter/? Shared by the Deploy flow's mobile deploy steps.
#
#   bin/card_touched_flutter.sh <REF>
#
# Exit 0: the card's NEWEST origin/main commit (subject `<REF> …`) changes a path under flutter/.
# Exit 1: it doesn't, or no such commit exists on origin/main.
# Exit 2: usage error (no ref).
#
# The subject match carries a trailing space so RE40 never matches `RE408 …`, and only the
# SUBJECT counts (`--grep` alone matches any message line). Only the newest card commit counts:
# a re-shipped card is judged by what it shipped last.
#
# No `git diff | grep -q` here: under pipefail, grep exiting on its first match SIGPIPEs a
# large diff and the pipeline reads as "did not touch flutter/". `git diff --quiet` with a
# pathspec answers the question without a pipe.
#
# Read-only: never updates remote refs and never moves HEAD — the Deploy flow has already
# checked out origin/main.

set -euo pipefail

say() { echo "card_touched_flutter: $*" >&2; }

ref="${1:-}"
if [ -z "$ref" ]; then
  echo "usage: bin/card_touched_flutter.sh <REF>" >&2
  exit 2
fi

sha=""
while IFS=$'\t' read -r candidate subject; do
  case "$subject" in
    "$ref "*)
      sha="$candidate"
      break
      ;;
  esac
done < <(git log origin/main --format=$'%H\t%s' --grep="^$ref ")
if [ -z "$sha" ]; then
  say "no commit for $ref on origin/main — treating as no flutter/ change"
  exit 1
fi

if ! git diff --quiet "$sha^" "$sha" -- flutter/; then
  say "$ref ($(git rev-parse --short "$sha")) touched flutter/"
  exit 0
fi

say "$ref ($(git rev-parse --short "$sha")) did not touch flutter/"
exit 1
