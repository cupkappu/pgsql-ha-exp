#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SOURCE_DIR/scripts/manual-lib.sh"

node="${1:?usage: manual-promote.sh NODE}"
other="$(manual_other_node "$node")"

[[ "$(manual_role "$node")" == standby ]] || {
  echo "${node} is not standby" >&2
  exit 1
}

[[ "$(manual_role "$other")" == stopped ]] || {
  echo "${other} is still running" >&2
  exit 1
}

manual_inner_docker "$node" exec -u postgres "$MANUAL_CONTAINER" \
  /usr/lib/postgresql/16/bin/pg_ctl \
  -D /var/lib/postgresql/data promote -w >/dev/null

manual_wait_for "${node} promotion" 60 manual_role_is "$node" primary
printf '%s promoted\n' "$node"
manual_print_roles
