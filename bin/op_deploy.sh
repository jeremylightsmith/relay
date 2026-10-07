#!/usr/bin/env bash
# Run a deploy command with its secrets resolved by 1Password.
#
#   bin/op_deploy.sh <command> [args...]      e.g. bin/op_deploy.sh bin/deploy_fly.sh
#
# When the 1Password CLI is installed and signed in, replaces itself with
#   op run --env-file=<repo root>/.relay/deploy.env -- <command> [args...]
# so the secrets exist only in that command's environment. See .relay/deploy.env for the vault
# layout. Headless runners sign in with a service account via OP_SERVICE_ACCOUNT_TOKEN.
#
# Without a signed-in `op`, the command runs on the environment it inherited (the runner's
# shell, e.g. secrets exported from .envrc.local), plus the env file's non-secret literals for
# any name not already set. An `op://` reference is never exported, so a secret missing from
# the environment stays missing and the deploy script names it.

set -euo pipefail

say() { echo "op_deploy: $*" >&2; }

if [ "$#" -eq 0 ]; then
  echo "usage: bin/op_deploy.sh <command> [args...]" >&2
  exit 2
fi

root="$(git rev-parse --show-toplevel)"
env_file="$root/.relay/deploy.env"

if command -v op >/dev/null 2>&1 && op whoami >/dev/null 2>&1; then
  exec op run --env-file="$env_file" -- "$@"
fi

say "1Password (op) not installed or not signed in — using the inherited environment"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in "" | "#"* | *=op://*) continue ;; esac
  name="${line%%=*}"
  if [ -z "${!name+set}" ]; then export "$name=${line#*=}"; fi
done < "$env_file"
exec "$@"
