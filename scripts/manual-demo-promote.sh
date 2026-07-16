#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SOURCE_DIR/scripts/manual-demo-lib.sh"

node="${1:?usage: manual-demo-promote.sh NODE}"
other="$(manual_demo_other_node "$node")"

[[ "$(manual_demo_role "$node")" == standby ]] || {
  echo "${node} is not standby" >&2
  exit 1
}

[[ "$(manual_demo_role "$other")" == stopped ]] || {
  echo "${other} is still running; stop it before promotion" >&2
  exit 1
}

manual_demo_compose exec -T -u postgres "$node" \
  /usr/lib/postgresql/16/bin/pg_ctl \
  -D /var/lib/postgresql/data/pgdata promote -w >/dev/null

manual_demo_wait_for "${node} promotion" 60 manual_demo_role_is "$node" primary
printf '%s promoted\n' "$node"
manual_demo_print_roles
