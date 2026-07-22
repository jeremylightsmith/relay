#!/usr/bin/env sh
# Relay prepare hook (RLY-231): warm a freshly created per-card worktree so a Code run does not
# pay a full deps.get + clean compile. Boring first cut — copy deps/_build/node_modules from a
# warm base using APFS clonefile copy-on-write (near-free, each worktree gets its own writable
# copy), falling back to a plain recursive copy on non-CoW filesystems. Reflink/tarball/container
# restore and a shared read-only dep cache are deferred optimizations this hook can adopt later
# with NO change to Relay core.
#
# Invoked by bin/relay right after `git worktree add`, cwd = the new worktree. Inputs arrive as
# both argv and env. A nonzero exit FAILS the run (fail-fast) — a broken cache surfaces at once.
#
#   $1/$RELAY_WORKTREE   abs path of the new worktree (== cwd)
#   $2/$RELAY_REF        card ref (e.g. RLY-231)
#   $3/$RELAY_BRANCH     branch the run will attach
#   $4/$RELAY_BASE       base ref (origin/main)
#   $5/$RELAY_CACHE_DIR  configured cache dir (may be empty)
set -eu

WORKTREE="${RELAY_WORKTREE:-$1}"
CACHE_DIR="${RELAY_CACHE_DIR:-}"

# The warm source: the configured cache dir if it holds the dirs, else the main checkout's own
# already-warm dirs (the repo you ran `relay execute` from). git's common dir points at the main
# checkout's .git; its parent is that checkout's root.
MAIN_ROOT="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git/*$##')"

copy_dir() {
  # copy_dir <name>: clone <src>/<name> into $WORKTREE/<name> if the destination is missing.
  name="$1"
  dest="$WORKTREE/$name"
  [ -e "$dest" ] && return 0
  src=""
  if [ -n "$CACHE_DIR" ] && [ -d "$CACHE_DIR/$name" ]; then
    src="$CACHE_DIR/$name"
  elif [ -n "$MAIN_ROOT" ] && [ -d "$MAIN_ROOT/$name" ]; then
    src="$MAIN_ROOT/$name"
  fi
  [ -z "$src" ] && return 0     # nothing warm to copy → a cold build is correct, not an error
  # -c = APFS clonefile (copy-on-write); fall back to a plain recursive copy elsewhere.
  cp -Rc "$src" "$dest" 2>/dev/null || cp -R "$src" "$dest"
}

copy_dir deps
copy_dir _build
copy_dir assets/node_modules
echo "prepare-worktree: warmed $WORKTREE from ${CACHE_DIR:-$MAIN_ROOT}"
