#!/usr/bin/env bash
# Ship a card's branch to main as ONE squashed commit — the RE board Code flow's `merge` step.
#
#   bin/ship_to_main.sh <REF>
#
# Squashes origin/main..HEAD into a single `<REF> <card title>` commit (body: one `* <subject>`
# line per squashed commit, oldest first, then a Co-Authored-By trailer), pushes it to main as
# a plain fast-forward, and comments `Shipped to main as <short-sha>` on the card.
#
# Exits 0 when shipped, or when there is nothing to ship (origin/main..HEAD is empty — so a
# re-run after a successful ship is a no-op). Exits nonzero on a missing argument, a card with
# no title (the `<REF> ` subject is how card_touched_flutter.sh finds the commit), or a rejected
# push. A failed card comment AFTER a successful push only warns: the code is on main, and a
# nonzero exit would send the flow back through resync for a ship that already happened.
#
# The squash happens before the push, so a rejected push leaves the local branch squashed. After
# the resync rebase a re-run's body lists only `* <REF> <title>` rather than the original
# subjects — the shipped tree is the same, only the body's history summary is coarser.
#
# Why it never forces and never re-reads the remote: the flow's `resync` node already brought
# origin/main up to date. If main moved since then, the plain push MUST be rejected so the
# flow's `merge -> resync` edge rebases; refreshing and resetting here would silently squash
# someone else's commits into this card's commit.
#
# The Relay CLI is called as "${RELAY:-./relay}" (tests point RELAY at a stub).

set -euo pipefail

say() { echo "ship_to_main: $*" >&2; }

ref="${1:-}"
if [ -z "$ref" ]; then
  echo "usage: bin/ship_to_main.sh <REF>" >&2
  exit 64
fi
relay="${RELAY:-./relay}"

if [ -z "$(git rev-list origin/main..HEAD)" ]; then
  say "nothing to ship — origin/main..HEAD is empty"
  exit 0
fi

base="$(git merge-base origin/main HEAD)"
title="$("$relay" card "$ref" --field title)"
if [ -z "${title//[[:space:]]/}" ]; then
  say "card $ref has no title — refusing to ship a commit card_touched_flutter.sh cannot find"
  exit 1
fi

msg="$(mktemp)"
trap 'rm -f "$msg"' EXIT
{
  printf '%s %s\n\n' "$ref" "$title"
  git log --reverse --format='* %s' "$base..HEAD"
  printf '\nCo-Authored-By: Claude <noreply@anthropic.com>\n'
} >"$msg"

git reset -q --soft "$base"
git commit -q --cleanup=whitespace -F "$msg"

say "pushing $(git rev-parse --short HEAD) to main"
git push origin HEAD:main

sha="$(git rev-parse --short HEAD)"
if ! "$relay" comment "$ref" "Shipped to main as $sha"; then
  say "warning: could not comment on $ref (shipped as $sha) — post it by hand"
fi
say "shipped $ref as $sha"
