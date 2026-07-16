#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SOURCE_DIR/scripts/manual-demo-lib.sh"

manual_demo_compose ps -a
printf '\n'
manual_demo_print_roles

primary="$(manual_demo_primary_node 2>/dev/null || true)"
standby="$(manual_demo_standby_node 2>/dev/null || true)"

if [[ -n "$primary" ]]; then
  printf '\nprimary replication state (%s):\n' "$primary"
  manual_demo_psql "$primary" postgres postgres "$POSTGRES_PASSWORD" \
    "SELECT application_name, client_addr, state, sync_state,
            pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint AS lag_bytes
       FROM pg_stat_replication
      ORDER BY application_name;" || true
fi

if [[ -n "$standby" ]]; then
  printf '\nstandby receiver state (%s):\n' "$standby"
  manual_demo_psql "$standby" postgres postgres "$POSTGRES_PASSWORD" \
    "SELECT status, sender_host, sender_port, latest_end_lsn
       FROM pg_stat_wal_receiver;" || true
fi
