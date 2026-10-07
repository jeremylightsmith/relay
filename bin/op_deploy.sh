#!/usr/bin/env bash
# Run a deploy command with its secrets resolved by 1Password.
#
#   bin/op_deploy.sh <command> [args...]      e.g. bin/op_deploy.sh bin/deploy_fly.sh
#
# Checks that the 1Password CLI is installed and signed in, then replaces itself with
#   op run --env-file=<repo root>/.relay/deploy.env -- <command> [args...]
# so the secrets exist only in that command's environment. See .relay/deploy.env for the vault
# layout. Headless runners sign in with a service account via OP_SERVICE_ACCOUNT_TOKEN.

set -euo pipefail

say() { echo "op_deploy: $*" >&2; }

if [ "$#" -eq 0 ]; then
  echo "usage: bin/op_deploy.sh <command> [args...]" >&2
  exit 2
fi

if ! command -v op >/dev/null 2>&1; then
  say "1Password CLI (op) is not installed — install it and sign in; headless runners need OP_SERVICE_ACCOUNT_TOKEN"
  exit 1
fi

if ! op whoami >/dev/null 2>&1; then
  say "op is not signed in — run \`op signin\`, or set OP_SERVICE_ACCOUNT_TOKEN on a headless runner"
  exit 1
fi

root="$(git rev-parse --show-toplevel)"
exec op run --env-file="$root/.relay/deploy.env" -- "$@"
