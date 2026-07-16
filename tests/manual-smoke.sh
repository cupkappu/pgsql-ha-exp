#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SOURCE_DIR/scripts/manual-lib.sh"

manual_cluster_ready
primary="$(manual_primary_node)"
standby="$(manual_standby_node)"
marker="manual-smoke-$(date +%s)"

manual_client_psql "$primary" app appdb "$MANUAL_APP_PASSWORD" \
  "CREATE TABLE IF NOT EXISTS manual_probe (
     id bigserial PRIMARY KEY,
     marker text UNIQUE NOT NULL,
     created_at timestamptz NOT NULL DEFAULT now()
   );
   INSERT INTO manual_probe(marker) VALUES ('${marker}');" >/dev/null

replica_has_marker() {
  [[ "$(manual_client_psql "$standby" app appdb "$MANUAL_APP_PASSWORD" \
    "SELECT marker FROM manual_probe WHERE marker='${marker}'" 2>/dev/null || true)" == "$marker" ]]
}

manual_wait_for 'probe row on standby' 60 replica_has_marker

replication_count="$(manual_node_psql "$primary" postgres postgres "$MANUAL_SUPERUSER_PASSWORD" \
  "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'")"
[[ "$replication_count" == 1 ]]

printf '[PASS] manual primary/standby smoke test passed: %s primary, %s standby\n' \
  "$primary" "$standby"
