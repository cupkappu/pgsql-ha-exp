#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SOURCE_DIR/scripts/manual-demo-lib.sh"

from="${1:?usage: manual-demo-switch.sh FROM TO}"
to="${2:?usage: manual-demo-switch.sh FROM TO}"

[[ "$(manual_demo_other_node "$from")" == "$to" ]] || {
  echo 'FROM and TO must be db1/db2' >&2
  exit 1
}
[[ "$(manual_demo_role "$from")" == primary ]] || {
  echo "${from} is not primary" >&2
  exit 1
}
[[ "$(manual_demo_role "$to")" == standby ]] || {
  echo "${to} is not standby" >&2
  exit 1
}

manual_demo_psql "$from" postgres postgres "$POSTGRES_PASSWORD" 'CHECKPOINT' >/dev/null
target_lsn="$(manual_demo_psql "$from" postgres postgres "$POSTGRES_PASSWORD" \
  'SELECT pg_switch_wal()')"

replay_reached() {
  [[ "$(manual_demo_psql "$to" postgres postgres "$POSTGRES_PASSWORD" \
    "SELECT COALESCE(pg_last_wal_replay_lsn() >= '${target_lsn}'::pg_lsn, false)" \
    2>/dev/null || true)" == t ]]
}

manual_demo_wait_for "${to} replay through ${target_lsn}" 60 replay_reached
manual_demo_compose stop "$from" >/dev/null
bash "$SOURCE_DIR/scripts/manual-demo-promote.sh" "$to"
