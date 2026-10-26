#!/bin/sh
# End-to-end check of the relay -> hamaca rename (RE478), run by hand against a live board.
#
#   bin/e2e_runner_rename.sh [BASE_REF]
#
# Needs HAMACA_URL (or RELAY_URL) and HAMACA_API_KEY (or RELAY_API_KEY) for a board running
# this branch (e.g. `mix phx.server`). BASE_REF (default: the merge-base of HEAD and
# origin/main) supplies the "installed before the rename" repo: its v93 `relay`, `relay.md`,
# `.relay/runner.json` and the three `relay-*` skills, seeded into a throwaway git repo.
#
# It proves that repo keeps working untouched (`./relay board`, `./relay update --check` rename
# nothing), then migrates in two `./relay update`s (the first installs the new full runner as
# ./relay, the second renames the repo to the Hamaca names), that both names work afterwards
# with no shim note in a pipe, and that a third `./relay update` is a no-op.
#
# Prints PASS and exits 0, or `FAIL: <step>` (plus the step's output and the temp dir, which
# is kept for inspection) and exits 1. Not part of `mix precommit`: it needs a running board.

set -eu

say() { echo "e2e_runner_rename: $*"; }

fail() {
  echo "FAIL: $*"
  if [ -n "${log:-}" ] && [ -s "$log" ]; then
    sed 's/^/  | /' "$log"
  fi
  echo "temp dir kept at $tmp"
  exit 1
}

url="${HAMACA_URL:-${RELAY_URL:-}}"
key="${HAMACA_API_KEY:-${RELAY_API_KEY:-}}"
if [ -z "$url" ] || [ -z "$key" ]; then
  echo "usage: HAMACA_URL=... HAMACA_API_KEY=... bin/e2e_runner_rename.sh [BASE_REF]" >&2
  echo "  (RELAY_URL / RELAY_API_KEY are read too)" >&2
  exit 64
fi

app="$(git rev-parse --show-toplevel)"
base="${1:-$(git -C "$app" merge-base HEAD origin/main)}"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/e2e_runner_rename.XXXXXX")"
repo="$tmp/repo"
log=""

# A user's terminal: the board under both names (a v93 runner reads only RELAY_*), and none of
# the per-node variables a flow node exports, so nothing here looks like a node subprocess.
export HAMACA_URL="$url" RELAY_URL="$url" HAMACA_API_KEY="$key" RELAY_API_KEY="$key"
for suffix in NODE_SCRATCH NODE_OUTCOME PLAN; do
  unset "HAMACA_$suffix" "RELAY_$suffix"
done

# step NAME CMD... — run CMD in the repo with its output in $tmp/NAME.log; FAIL on nonzero.
step() {
  name="$1"
  shift
  log="$tmp/$name.log"
  (cd "$repo" && "$@") >"$log" 2>&1 || fail "$name (exit $?)"
}

# expect NAME TEXT — the last step's output contains TEXT.
expect() {
  grep -qF -- "$2" "$log" || fail "$1: output lacks \"$2\""
}

present() {
  for path in "$@"; do
    [ -e "$repo/$path" ] || fail "migrate: $path is missing"
  done
}

absent() {
  for path in "$@"; do
    [ ! -e "$repo/$path" ] || fail "migrate: $path is still there"
  done
}

files() { (cd "$repo" && find . -path ./.git -prune -o -type f -print | sort); }

seed() {
  mkdir -p "$(dirname "$repo/$1")"
  git -C "$app" show "$base:$1" >"$repo/$1" || fail "seed: $base has no $1"
}

say "seeding $repo from $base"
mkdir -p "$repo"
git -C "$repo" init -q
seed relay
chmod 755 "$repo/relay"
seed relay.md
seed .relay/runner.json
for skill in doctor onboard update; do
  seed ".claude/skills/relay-$skill/SKILL.md"
done
git -C "$repo" add -A
git -C "$repo" -c user.email=e2e@hamaca.invalid -c user.name=e2e commit -q -m "v93 install"
grep -q '^RUNNER_VERSION = 93$' "$repo/relay" || fail "seed: $base's relay is not v93"

say "the untouched v93 repo keeps working"
before="$(files)"
step untouched-board ./relay board
step untouched-check ./relay update --check
[ "$(files)" = "$before" ] || fail "untouched-check: a file was renamed or written"

say "two ./relay updates migrate it"
step install-runner ./relay update
version="$(sed -n 's/^RUNNER_VERSION = \([0-9][0-9]*\)$/\1/p' "$repo/relay")"
[ "${version:-0}" -ge 94 ] || fail "install-runner: ./relay is v${version:-?}, expected 94+"
step migrate ./relay update
expect migrate "renamed to Hamaca ("
present hamaca .hamaca/runner.json hamaca.md \
  .claude/skills/hamaca-doctor/SKILL.md \
  .claude/skills/hamaca-onboard/SKILL.md \
  .claude/skills/hamaca-update/SKILL.md
absent .relay relay.md

say "both names work, and a pipe carries no shim note"
step hamaca-board ./hamaca board
log="$tmp/relay-board.log"
rc="$({ (cd "$repo" && ./relay board 2>&1); echo "$?" >"$tmp/relay-board.rc"; } | cat >"$log"; cat "$tmp/relay-board.rc")"
[ "$rc" = 0 ] || fail "relay-board (exit $rc)"
if grep -q 'note:' "$log"; then
  fail "relay-board: the piped output carries a note"
fi

say "a third ./relay update is a no-op"
status="$(git -C "$repo" status --porcelain)"
step rerun ./relay update
expect rerun "already on Hamaca names"
[ "$(git -C "$repo" status --porcelain)" = "$status" ] || fail "rerun: git status changed"

rm -rf "$tmp"
echo PASS
