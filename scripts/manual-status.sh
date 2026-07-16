#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SOURCE_DIR/scripts/manual-lib.sh"

printf '%s\n' '== Docker hosts =='
docker ps -a --filter 'name=clab-pgsql-manual-' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

printf '\n%s\n' '== PostgreSQL roles =='
manual_print_roles

primary="$(manual_primary_node 2>/dev/null || true)"
if [[ -n "$primary" ]]; then
  printf '\n== replication on %s ==\n' "$primary"
  manual_node_psql "$primary" postgres postgres "$MANUAL_SUPERUSER_PASSWORD" \
    "SELECT application_name, client_addr, state, sync_state,
            pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint AS replay_lag_bytes
       FROM pg_stat_replication
       ORDER BY application_name;" || true
fi
