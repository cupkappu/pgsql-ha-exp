#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SOURCE_DIR/scripts/manual-lib.sh"

node="${1:?usage: manual-rejoin.sh NODE}"
primary="$(manual_other_node "$node")"

[[ "$(manual_role "$primary")" == primary ]] || {
  echo "${primary} is not primary" >&2
  exit 1
}

manual_inner_docker "$node" stop "$MANUAL_CONTAINER" >/dev/null 2>&1 || true
manual_clone_from "$node" "$primary"
manual_start_postgres "$node"
manual_wait_for "${node} standby" 120 manual_postgres_ready "$node"

if [[ "$(manual_role "$node")" != standby ]]; then
  echo "${node} did not join as standby" >&2
  exit 1
fi

printf '%s rejoined from %s\n' "$node" "$primary"
manual_print_roles
